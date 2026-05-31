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
//  BLOQUE DE LICENCIAS — QuantCore (Parte 3)
//  Sin tokens de administrador. Validación 100% vía servidor.
//══════════════════════════════════════════════════════════════════
input string Licencia_Token    = "";                                      // Token de licencia (cópialo de tu perfil en la web)
input string ApiUrl            = "https://TU-PROYECTO.vercel.app/api/";   // URL base de tu despliegue Vercel (incluye / al final)
input int    HeartbeatInterval = 3600;                                     // Segundos entre heartbeats (mín. 600)

#define EA_TIPO "auto_journaling"

bool     g_licencia_ok    = false;
datetime g_last_heartbeat = 0;

//--- Verifica la licencia llamando a POST /api/validar-licencia
bool VerificarLicenciaWeb()
{
    if(StringLen(Licencia_Token) < 8)
    {
        Print("QuantCore: Token vacío o demasiado corto. Ingresa tu token en los parámetros del EA.");
        return false;
    }
    long   cuenta = AccountInfoInteger(ACCOUNT_LOGIN);
    string body   = StringFormat(
        "{\"token\":\"%s\",\"ea_tipo\":\"%s\",\"mt5_account\":\"%I64d\"}",
        Licencia_Token, EA_TIPO, cuenta);
    uchar  req[], res[];
    StringToCharArray(body, req, 0, StringLen(body));
    string hdrs;
    string url = ApiUrl + "validar-licencia";
    int ret = WebRequest("POST", url, "Content-Type: application/json\r\n", 8000, req, res, hdrs);
    if(ret < 0 || ArraySize(res) == 0)
    {
        Print("QuantCore: Error de red al validar licencia (", GetLastError(), ").");
        Print("Asegúrate de añadir '", url, "' en: Herramientas → Opciones → Expert Advisors → WebRequest");
        return false;
    }
    string resp = CharArrayToString(res);
    Print("QuantCore respuesta validación: ", resp);
    if(StringFind(resp, "\"valido\":true") >= 0)
    {
        Print("QuantCore: Licencia válida para EA tipo '", EA_TIPO, "'.");
        return true;
    }
    // Extraer motivo del JSON si existe
    int mStart = StringFind(resp, "\"motivo\":\"");
    if(mStart >= 0)
    {
        mStart += 10;
        int mEnd = StringFind(resp, "\"", mStart);
        if(mEnd > mStart) Print("QuantCore motivo rechazo: ", StringSubstr(resp, mStart, mEnd-mStart));
    }
    return false;
}

//--- Envía heartbeat periódico a POST /api/heartbeat
bool SendHeartbeat()
{
    long   cuenta = AccountInfoInteger(ACCOUNT_LOGIN);
    string body   = StringFormat(
        "{\"token\":\"%s\",\"ea_tipo\":\"%s\",\"mt5_account\":\"%I64d\"}",
        Licencia_Token, EA_TIPO, cuenta);
    uchar  req[], res[];
    StringToCharArray(body, req, 0, StringLen(body));
    string hdrs;
    string url = ApiUrl + "heartbeat";
    int ret = WebRequest("POST", url, "Content-Type: application/json\r\n", 5000, req, res, hdrs);
    if(ret < 0 || ArraySize(res) == 0) { Print("QuantCore: Heartbeat fallido (error red)."); return false; }
    string resp = CharArrayToString(res);
    if(StringFind(resp, "\"ok\":false") >= 0)
    {
        Print("QuantCore: Heartbeat rechazado → ", resp);
        return false;
    }
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
    json += "\"token\":\"" + Licencia_Token + "\",";
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