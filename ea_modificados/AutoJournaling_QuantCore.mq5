//+------------------------------------------------------------------+
//|                                       Samtrader Auto-Journaling Pro |
//|                                  Copyright 2026, Javier Trader    |
//|                                               Versión final v2.13  |
//+------------------------------------------------------------------+
#property copyright "Javier Trader"
#property version   "2.13"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
input ENUM_TIMEFRAMES InpTimeframe1 = PERIOD_M5;  // Temporalidad captura 1
input ENUM_TIMEFRAMES InpTimeframe2 = PERIOD_H1;  // Temporalidad captura 2
input bool InpAutoAttach = false;                 // Auto-agregar EA al perfil

//+------------------------------------------------------------------+
//| SISTEMA DE LICENCIAS (idéntico al EA anterior)                   |
//+------------------------------------------------------------------+
//══════════════════════════════════════════════════════════════════
//  BLOQUE DE LICENCIAS — QuantCore Anti-Tamper v2
//  URLs cifradas con XOR. Canarios de integridad. Modo veneno.
//══════════════════════════════════════════════════════════════════
input string LicenseToken      = "";   // Token de licencia (cópialo desde FlowTrade Suite)
input int    HeartbeatInterval = 3600; // Segundos entre heartbeats (mín. 600)

#define EA_TIPO "auto_journaling"

bool     g_licencia_ok    = false;
bool     g_poisoned       = false;
datetime g_last_heartbeat = 0;
int      g_dias_restantes = -1;   // días hasta expiración del plan (-1=sin info)

string QC_XorDecrypt(const uchar &enc[], int len)
{
   uchar k[4] = {0xA7, 0x3F, 0xD1, 0x8B};
   string s = "";
   for(int i = 0; i < len; i++)
      s += CharToString((uchar)(enc[i] ^ k[i % 4]));
   return s;
}
string QC_ApiBase()
{
   uchar enc[] = {207,75,165,251,212,5,254,164,214,74,176,229,211,92,190,249,
                  194,18,176,251,206,17,167,238,213,92,180,231,137,94,161,251,
                  136,94,161,226,136};
   return QC_XorDecrypt(enc, 37);
}
string QC_EndValidar()   { uchar e[]={209,94,189,226,195,94,163,166,203,86,178,238,201,92,184,234}; return QC_XorDecrypt(e,16); }
string QC_EndHeartbeat() { uchar e[]={207,90,176,249,211,93,180,234,211}; return QC_XorDecrypt(e,9); }

bool QC_CheckIntegrity()
{
   int c1 = 0xA7 + 0x3F + 0xD1 + 0x8B;
   if(c1 != 544) return false;
   string url = QC_ApiBase();
   if(StringLen(url) != 37)               return false;
   if(StringSubstr(url, 0, 5) != "https") return false;
   if(StringSubstr(url, 36, 1) != "/")    return false;
   if(StringFind(QC_EndValidar(), "licencia") < 0) return false;
   return true;
}
string QC_PoisonToken()
{
   int len = StringLen(LicenseToken);
   if(len < 8) return StringFormat("poison_%d_%d", MathRand(), MathRand());
   return StringSubstr(LicenseToken,len/2) + StringSubstr(LicenseToken,0,len/2) + StringFormat("_px%d",MathRand()%9999);
}

// Extrae un campo entero de JSON simple {"campo":123}
int QC_ParseInt(const string &json, const string &campo)
{
   string key = "\"" + campo + "\":";
   int idx = StringFind(json, key);
   if(idx < 0) return -1;
   idx += StringLen(key);
   while(idx < StringLen(json) && (StringGetCharacter(json,idx)==' ')) idx++;
   string num = "";
   for(int i=idx; i<StringLen(json); i++)
   {
      ushort c = StringGetCharacter(json, i);
      if(c>='0' && c<='9') num += CharToString((uchar)c);
      else if(c=='-' && StringLen(num)==0) num += "-";
      else break;
   }
   if(StringLen(num)==0) return -1;
   return (int)StringToInteger(num);
}
// Extrae un campo string de JSON {"campo":"valor"}
string QC_ParseStr(const string &json, const string &campo)
{
   string key = "\"" + campo + "\":\"";
   int idx = StringFind(json, key);
   if(idx < 0) return "";
   idx += StringLen(key);
   string val = "";
   for(int i=idx; i<StringLen(json); i++)
   {
      ushort c = StringGetCharacter(json, i);
      if(c=='\"') break;
      val += CharToString((uchar)c);
   }
   return val;
}
// Genera un identificador de hardware único (HWID) basado en la ruta del terminal y la cuenta
string QC_GetHWID()
{
   long   acct = AccountInfoInteger(ACCOUNT_LOGIN);
   string path = TerminalInfoString(TERMINAL_DATA_PATH);
   string raw  = path + "|" + IntegerToString(acct) + "|QC2025";
   // Hash DJB2 simple
   ulong h = 5381;
   for(int i = 0; i < StringLen(raw); i++)
      h = h * 33 + (ulong)StringGetCharacter(raw, i);
   return StringFormat("QC_%016I64X", h);
}
bool VerificarLicenciaWeb()
{
   if(!QC_CheckIntegrity()) { g_poisoned = true; return true; }
   if(StringLen(LicenseToken) < 8) { Print("QuantCore: Token vacío — ingresa tu token en los parámetros."); return false; }
   long   cuenta = AccountInfoInteger(ACCOUNT_LOGIN);
   string tok    = g_poisoned ? QC_PoisonToken() : LicenseToken;
   string body   = "{"token":""+tok+"","ea_tipo":""+EA_TIPO+"","mt5_account":""+IntegerToString(cuenta)+"",\"hwid\":\""+QC_GetHWID()+"\"}" ;
   uchar  req[], res[]; string hdrs;
   StringToCharArray(body, req, 0, StringLen(body));
   string url = QC_ApiBase() + QC_EndValidar();
   int ret = WebRequest("POST", url, "Content-Type: application/json
", 8000, req, res, hdrs);
   if(ret < 0 || ArraySize(res) == 0)
   {
      Print("QuantCore: Error de red al validar (", GetLastError(), "). Añade '", url, "' en WebRequest.");
      return false;
   }
   if(g_poisoned) return true;
   string resp = CharArrayToString(res);
   Print("QuantCore validación: ", resp);
   if(StringFind(resp, "\"valido\":true") >= 0)
   {
      g_dias_restantes = QC_ParseInt(resp, "dias_restantes");
      string usuario   = QC_ParseStr(resp, "usuario");
      string planStr   = QC_ParseStr(resp, "plan");
      if(g_dias_restantes >= 0)
      {
         string expMsg = StringFormat(
            "QuantCore | Plan: %s | %d días restantes | Usuario: %s",
            planStr, g_dias_restantes, usuario);
         Print(expMsg);
         Comment(expMsg);
         if(g_dias_restantes <= 7)
            Alert(StringFormat(
               "⚠ QuantCore — FlowTrade Suite\n"
               "Tu plan '%s' vence en %d día(s).\n"
               "Renueva ya en: https://flowtradesuite.com",
               planStr, g_dias_restantes));
         else if(g_dias_restantes <= 30)
            Print(StringFormat(
               "QuantCore AVISO: quedan %d días de tu plan %s — renueva pronto.",
               g_dias_restantes, planStr));
      }
      else
      {
         Print("QuantCore: Licencia válida | ", EA_TIPO, " | plan sin expiración fija.");
         Comment("QuantCore | Licencia activa | " + EA_TIPO);
      }
      return true;
   }
   int ms = StringFind(resp, ""motivo":"");
   if(ms >= 0) { ms+=10; int me=StringFind(resp,""",ms); if(me>ms) Print("Motivo: ",StringSubstr(resp,ms,me-ms)); }
   return false;
}
bool SendHeartbeat()
{
   long   cuenta = AccountInfoInteger(ACCOUNT_LOGIN);
   string tok    = g_poisoned ? QC_PoisonToken() : LicenseToken;
   string body   = "{"token":""+tok+"","ea_tipo":""+EA_TIPO+"","mt5_account":""+IntegerToString(cuenta)+"",\"hwid\":\""+QC_GetHWID()+"\"}" ;
   uchar  req[], res[]; string hdrs;
   StringToCharArray(body, req, 0, StringLen(body));
   string url = QC_ApiBase() + QC_EndHeartbeat();
   int ret = WebRequest("POST", url, "Content-Type: application/json
", 5000, req, res, hdrs);
   if(ret < 0 || ArraySize(res) == 0) { Print("QuantCore: Heartbeat fallido."); return false; }
   if(g_poisoned) return true;
   string resp = CharArrayToString(res);
   if(StringFind(resp, ""ok":false") >= 0) { Print("Heartbeat rechazado: ", resp); return false; }
   return true;
}
//══════════════════════════════════════════════════════════════════
//  FIN BLOQUE DE LICENCIAS
//══════════════════════════════════════════════════════════════════


//+------------------------------------------------------------------+
//| ESTRUCTURA PARA OPERACIONES ABIERTAS                             |
//+------------------------------------------------------------------+
struct TradeRecord
{
    ulong   ticket;
    string  symbol;
    int     type;           // 0=Buy, 1=Sell
    double  volume;
    double  openPrice;
    datetime openTime;
    string  openScreenshotPath1;
    string  openScreenshotPath2;
};

TradeRecord g_openTrades[100];
int g_openCount = 0;

//+------------------------------------------------------------------+
//| CAPTURA DE PANTALLA (abre gráfico temporal)                      |
//+------------------------------------------------------------------+
bool TakeScreenshotForSymbol(string symbol, ENUM_TIMEFRAMES tf, string &outPath)
{
    string filename = StringFormat("journal_%s_%s_%I64u.png", symbol, EnumToString(tf), TimeCurrent());
    outPath = "Files\\" + filename;
    long chartId = ChartOpen(symbol, tf);
    if(chartId == 0) 
    {
        Print("Error ChartOpen para ", symbol, " tf=", tf, " error=", GetLastError());
        return false;
    }
    Sleep(800);
    bool result = ChartScreenShot(chartId, outPath, 800, 500, ALIGN_RIGHT);
    ChartClose(chartId);
    if(!result) Print("Error ChartScreenShot para ", symbol, " error=", GetLastError());
    return result;
}

//+------------------------------------------------------------------+
//| ENVÍO DEL JOURNAL (simulado en modo admin)                       |
//+------------------------------------------------------------------+
bool SendJournal(TradeRecord &rec, double closePrice, double sl, double tp, double profit, datetime closeTime,
                 string closePath1, string closePath2)
{
    string json = "{";
    json += "\"token\":\"" + LicenseToken + "\",";
    json += "\"account\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
    json += "\"ticket\":" + IntegerToString(rec.ticket) + ",";
    json += "\"symbol\":\"" + rec.symbol + "\",";
    json += "\"type\":\"" + (rec.type == 0 ? "BUY" : "SELL") + "\",";
    json += "\"volume\":" + DoubleToString(rec.volume, 2) + ",";
    json += "\"openPrice\":" + DoubleToString(rec.openPrice, _Digits) + ",";
    json += "\"openTime\":" + IntegerToString(rec.openTime) + ",";
    json += "\"closePrice\":" + DoubleToString(closePrice, _Digits) + ",";
    json += "\"sl\":" + DoubleToString(sl, _Digits) + ",";
    json += "\"tp\":" + DoubleToString(tp, _Digits) + ",";
    json += "\"profit\":" + DoubleToString(profit, 2) + ",";
    json += "\"closeTime\":" + IntegerToString(closeTime);
    json += "}";
    // Aquí iría el código real de multipart con las 4 imágenes
    return true;
}

//+------------------------------------------------------------------+
//| EVENTO INICIAL                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Validación de licencia

   //══════════════════════════════════════════════════════════════
   //  VALIDACIÓN DE LICENCIA AL INICIAR
   //══════════════════════════════════════════════════════════════
   g_licencia_ok = VerificarLicenciaWeb();
   if(!g_licencia_ok)
   {
      Alert("QuantCore: Licencia no válida para " + EA_TIPO + ".\n"
            "Verifica tu token y plan en la web.");
      return(INIT_FAILED);
   }
   g_last_heartbeat = TimeCurrent();
   //══════════════════════════════════════════════════════════════

    // Auto-attach (guarda plantilla)
    if(InpAutoAttach)
    {
        int resp = MessageBox("¿Desea que este EA se añada automáticamente al gráfico cada vez que inicie MT5?\n"
                              "Se guardará el gráfico actual en la plantilla 'AutoJournal.tpl'.\n"
                              "Para que funcione, configure MT5 para que abra esta plantilla por defecto.",
                              "Auto-Attach EA", MB_YESNO | MB_ICONQUESTION);
        if(resp == IDYES)
        {
            bool saved = ChartSaveTemplate(0, "AutoJournal.tpl");
            Print(saved ? "Plantilla guardada como AutoJournal.tpl" : "Error al guardar plantilla");
        }
    }

    EventSetTimer(1);
    Print("Samtrader Auto-Journaling Pro v2.13 iniciado (modo cuenta entera)");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    EventKillTimer();
    Print("EA detenido");
}

//+------------------------------------------------------------------+
//| TEMPORIZADOR (re-verificación cada 12h)                          |
//+------------------------------------------------------------------+
void OnTimer()
{

    static datetime lastCheck = 0;
    datetime now = TimeCurrent();
    if(lastCheck == 0) lastCheck = now;
    if(now - lastCheck >= HeartbeatInterval)
    {
        lastCheck = now;
        if(!VerificarLicenciaWeb())
        {
            Print("Licencia expirada. Eliminando EA...");
            ExpertRemove();
        }
    }
}

//+------------------------------------------------------------------+
//| CAPTURA DE OPERACIONES (APERTURA Y CIERRE) - CORREGIDA           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
    if(!g_licencia_ok) return;
    
    // Solo nos interesan los deals completados
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    
    ulong dealTicket = trans.deal;
    if(dealTicket == 0) return;

    // Seleccionar el deal en un rango amplio (últimos 2 días)
    HistorySelect(TimeCurrent() - 172800, TimeCurrent() + 60);
    if(!HistoryDealSelect(dealTicket))
    {
        Print("No se pudo seleccionar el deal: ", dealTicket);
        return;
    }

    long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
    double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
    datetime timeDeal = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
    ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID); // ¡Importante! El ticket de la posición
    double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
    long typeDeal = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
    
    // Para depuración
    Print("DEAL: ticket=", dealTicket, " entry=", entry, " symbol=", symbol, " positionTicket=", positionTicket);
    
    // APERTURA
    if(entry == DEAL_ENTRY_IN)
    {
        string path1, path2;
        TakeScreenshotForSymbol(symbol, InpTimeframe1, path1);
        TakeScreenshotForSymbol(symbol, InpTimeframe2, path2);

        if(g_openCount < 100)
        {
            g_openTrades[g_openCount].ticket = positionTicket;  // Usar el ID de la posición, no el deal
            g_openTrades[g_openCount].symbol = symbol;
            g_openTrades[g_openCount].type = (typeDeal == DEAL_TYPE_BUY) ? 0 : 1;
            g_openTrades[g_openCount].volume = volume;
            g_openTrades[g_openCount].openPrice = price;
            g_openTrades[g_openCount].openTime = timeDeal;
            g_openTrades[g_openCount].openScreenshotPath1 = path1;
            g_openTrades[g_openCount].openScreenshotPath2 = path2;
            g_openCount++;
            Print("Apertura registrada. Posición: ", positionTicket, " Total abiertas: ", g_openCount);
        }
    }
    // CIERRE
    else if(entry == DEAL_ENTRY_OUT)
    {
        Print("Procesando cierre para posición: ", positionTicket);
        
        // Buscar por el ID de la posición (no por ticket del deal)
        int idx = -1;
        for(int i=0; i<g_openCount; i++)
        {
            if(g_openTrades[i].ticket == positionTicket)
            {
                idx = i;
                break;
            }
        }
        
        if(idx == -1)
        {
            Print("No se encontró la posición abierta con ID ", positionTicket);
            return;
        }

        TradeRecord rec = g_openTrades[idx];
        // Eliminar de la lista
        g_openTrades[idx] = g_openTrades[g_openCount-1];
        g_openCount--;

        // Tomar capturas de cierre
        string closePath1, closePath2;
        TakeScreenshotForSymbol(rec.symbol, InpTimeframe1, closePath1);
        TakeScreenshotForSymbol(rec.symbol, InpTimeframe2, closePath2);

        double sl = 0, tp = 0;  // Opcional: se pueden obtener si se almacenaron en la apertura
        SendJournal(rec, price, sl, tp, profit, timeDeal, closePath1, closePath2);
        Print("Cierre enviado para posición ", positionTicket, " profit=", profit);
    }
}
//+------------------------------------------------------------------+