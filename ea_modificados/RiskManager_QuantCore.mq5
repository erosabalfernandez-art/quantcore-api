//+------------------------------------------------------------------+
//|               Risk Manager Visual Pro  v13.5                     |
//|               Copyright 2026, Javier Trader                      |
//|                                                                  |
//|  Incluye sistema de licencias por token + verificación web       |
//|  y todas las mejoras visuales y funcionales.                     |
//+------------------------------------------------------------------+
#property copyright "Javier Trader"
#property version   "13.50"

#include <Trade\Trade.mqh>

//══════════════════════════════════════════════════════════════════
//  BLOQUE DE LICENCIAS — QuantCore Anti-Tamper v2
//  URLs cifradas con XOR. Canarios de integridad. Modo veneno.
//══════════════════════════════════════════════════════════════════
input string LicenseToken      = "";   // Token de licencia (cópialo desde FlowTrade Suite)
input int    HeartbeatInterval = 3600; // Segundos entre heartbeats (mín. 600)

#define EA_TIPO "risk_manager"

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
//══════════════════════════════════════════════════════════════════

//══════════════════════════════════════════════════════════════════
//  COLORES
//══════════════════════════════════════════════════════════════════
#define CLR_BG          C'12,22,45'
#define CLR_BORDER      C'0,200,230'
#define CLR_ACCENT      C'0,180,200'
#define CLR_BUY         C'0,140,80'
#define CLR_SELL        C'180,40,40'
#define CLR_TOGGLE_ON   C'0,160,130'
#define CLR_TOGGLE_OFF  C'70,70,70'
#define CLR_SECTION     C'18,32,65'
#define CLR_DARK        C'8,14,38'
#define CLR_UTILS       C'20,40,70'
#define CLR_EXEC        C'40,30,70'
#define CLR_CLOSE       C'150,40,40'

//══════════════════════════════════════════════════════════════════
//  NOMBRES DE OBJETOS
//══════════════════════════════════════════════════════════════════
#define LINE_ENTRY   "LINE_Entry"
#define LINE_SL      "LINE_SL"
#define LINE_TP      "LINE_TP"
#define LBL_SL       "LINE_Lbl_SL"
#define LBL_TP       "LINE_Lbl_TP"
#define PANEL_PREFIX "PANEL_"

//══════════════════════════════════════════════════════════════════
//  INPUTS DE CONFIGURACIÓN
//══════════════════════════════════════════════════════════════════
input group "── Auto Breakeven ──"
input bool   InpBEEnabled    = true;
input int    InpBEActivate   = 20;
input int    InpBEOffset     = 2;

input group "── Trailing Stop ──"
input bool   InpTrailEnabled = true;
input int    InpTSActivate   = 30;
input int    InpTSDistance   = 15;
input int    InpTSStep       = 5;

input group "── Prop Firm (valores iniciales) ──"
input double InpMaxDailyDD   = 4.5;
input double InpMaxTotalDD   = 9.0;
input double InpDailyTarget  = 2.0;
input int    InpMaxPositions = 5;

//══════════════════════════════════════════════════════════════════
//  VARIABLES GLOBALES
//══════════════════════════════════════════════════════════════════
CTrade  trade;

double  risk_val    = 1.0;
bool    is_percent  = true;
bool    is_pending  = false;
bool    use_sl      = true;
bool    use_tp      = true;

int     panel_x     = 20;
int     panel_y     = 60;

bool    show_utils    = false;
bool    show_propfirm = false;
bool    show_exec     = false;
bool    panel_minimized = false;
bool    drag_enabled  = true;

bool    be_enabled    = true;
bool    trail_enabled = true;

bool    pf_enabled    = false;
bool    pf_daily_dd   = true;
bool    pf_total_dd   = true;
bool    pf_daily_tgt  = true;
bool    pf_max_pos    = true;
bool    pf_autoclose  = true;
bool    pf_lock_tgt   = false;

double  user_max_daily_dd  = 4.5;
double  user_max_total_dd  = 9.0;
double  user_daily_target  = 2.0;

double   g_start_bal   = 0;
double   g_day_start   = 0;
double   g_max_eq_day  = 0;
datetime g_last_reset  = 0;
bool     g_pf_locked   = false;
bool     g_trade_block = false;
string   g_block_reason = "";

//+------------------------------------------------------------------+
//| PROTOTIPOS                                                        |
//+------------------------------------------------------------------+
void UpdateCalculations(bool lot_was_edited);
void UpdateLabels();
void DrawPanel();
void ShowHideLine(string name, bool visible);
void CreateLine(string n, color c, double p);
void CreateRect(string n, int x, int y, int w, int h, color c, bool sel=false, bool border=false);
void CreateBtn(string n, int x, int y, int w, int h, string t, color bg, color txt=clrWhite);
void CreateLabel(string n, int x, int y, string t, int s, color c, bool right=false);
void CreateEdit(string n, int x, int y, int w, int h, string t, color bg, color txt);
void HandleButtonClick(string sp);
void DoAutoBreakeven();
void DoTrailingStop();
void CheckPropFirm();
void CheckDayReset();
void CloseAll();
void CloseWinners();
void CloseLosers();
void UpdatePropFirmDisplay();
double GetPip();
string ProgBar(double val, double maxVal, int bars=10);
void InitSLTPbyScreenPercent();

//+------------------------------------------------------------------+
//| POSICIONAR SL Y TP AL 10% DEL RANGO VISIBLE                      |
//+------------------------------------------------------------------+
void InitSLTPbyScreenPercent()
{
   double entry = ObjectGetDouble(0, LINE_ENTRY, OBJPROP_PRICE);
   if(entry <= 0) return;
   double max_price = ChartGetDouble(0, CHART_PRICE_MAX);
   double min_price = ChartGetDouble(0, CHART_PRICE_MIN);
   double range = max_price - min_price;
   if(range <= 0) range = SymbolInfoDouble(_Symbol, SYMBOL_BID) * 0.05;
   double tp_price = entry + range * 0.10;
   double sl_price = entry - range * 0.10;
   double margin = range * 0.02;
   if(tp_price > max_price - margin) tp_price = max_price - margin;
   if(sl_price < min_price + margin) sl_price = min_price + margin;
   if(ObjectFind(0, LINE_TP) >= 0) ObjectMove(0, LINE_TP, 0, 0, tp_price);
   if(ObjectFind(0, LINE_SL) >= 0) ObjectMove(0, LINE_SL, 0, 0, sl_price);
   UpdateLabels();
}

//+------------------------------------------------------------------+
//| ETIQUETA FLOTANTE                                                |
//+------------------------------------------------------------------+
void SetLineLabel(string nombre, double precio, ENUM_ANCHOR_POINT ancla, color col, string texto)
{
   if(ObjectFind(0, nombre) < 0) {
      ObjectCreate(0, nombre, OBJ_TEXT, 0, TimeCurrent(), precio);
      ObjectSetInteger(0, nombre, OBJPROP_COLOR,      col);
      ObjectSetInteger(0, nombre, OBJPROP_FONTSIZE,   9);
      ObjectSetString(0,  nombre, OBJPROP_FONT,       "Courier New");
      ObjectSetInteger(0, nombre, OBJPROP_ANCHOR,     ancla);
      ObjectSetInteger(0, nombre, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nombre, OBJPROP_HIDDEN,     true);
   }
   ObjectMove(0, nombre, 0, TimeCurrent(), precio);
   ObjectSetString(0, nombre, OBJPROP_TEXT, texto);
}

//+------------------------------------------------------------------+
//| ACTUALIZAR ETIQUETAS FLOTANTES                                   |
//+------------------------------------------------------------------+
void UpdateLabels()
{
   double sep = (ChartGetDouble(0, CHART_PRICE_MAX) - ChartGetDouble(0, CHART_PRICE_MIN)) * 0.01;
   if(sep <= 0) sep = SymbolInfoDouble(_Symbol, SYMBOL_BID) * 0.002;
   double p_ent = ObjectGetDouble(0, LINE_ENTRY, OBJPROP_PRICE);
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot = StringToDouble(ObjectGetString(0, PANEL_PREFIX+"Lot_Edit", OBJPROP_TEXT));
   if(use_tp && ObjectFind(0, LINE_TP) >= 0) {
      double p_tp = ObjectGetDouble(0, LINE_TP, OBJPROP_PRICE);
      double diff = MathAbs(p_ent - p_tp);
      double ganancia = (tick_size>0 && lot>0) ? (diff/tick_size)*tick_val*lot : 0;
      SetLineLabel(LBL_TP, p_tp+sep, ANCHOR_LOWER, clrLime, StringFormat("TP  +%.2f USD", ganancia));
   } else ObjectDelete(0, LBL_TP);
   if(use_sl && ObjectFind(0, LINE_SL) >= 0) {
      double p_sl = ObjectGetDouble(0, LINE_SL, OBJPROP_PRICE);
      double diff = MathAbs(p_ent - p_sl);
      double perdida = (tick_size>0 && lot>0) ? (diff/tick_size)*tick_val*lot : 0;
      SetLineLabel(LBL_SL, p_sl-sep, ANCHOR_UPPER, clrRed, StringFormat("SL  -%.2f USD", perdida));
   } else ObjectDelete(0, LBL_SL);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //══════════════════════════════════════════════════════════════
   //  VALIDACIÓN DE LICENCIA
   //══════════════════════════════════════════════════════════════

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

   EventSetTimer(1);
   
   g_start_bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_start  = g_start_bal;
   g_max_eq_day = AccountInfoDouble(ACCOUNT_EQUITY);
   g_last_reset = TimeCurrent();
   be_enabled    = InpBEEnabled;
   trail_enabled = InpTrailEnabled;
   user_max_daily_dd = InpMaxDailyDD;
   user_max_total_dd = InpMaxTotalDD;
   user_daily_target = InpDailyTarget;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ObjectsDeleteAll(0, PANEL_PREFIX);
   if(ObjectFind(0, LINE_ENTRY) < 0) {
      CreateLine(LINE_ENTRY, clrDodgerBlue, bid);
      CreateLine(LINE_SL,    clrRed,        bid - 0.0010);
      CreateLine(LINE_TP,    clrLime,       bid + 0.0010);
   }
   InitSLTPbyScreenPercent();
   trade.SetExpertMagicNumber(123456);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(10);
   ChartSetInteger(0, CHART_SHOW_ASK_LINE, false);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ShowHideLine(LINE_SL, use_sl);
   ShowHideLine(LINE_TP, use_tp);
   DrawPanel();
   UpdateCalculations(false);
   UpdateLabels();
   ChartRedraw();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ChartSetInteger(0, CHART_SHOW_ASK_LINE, true);
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ObjectDelete(0, LINE_ENTRY);
   ObjectDelete(0, LINE_SL);
   ObjectDelete(0, LINE_TP);
   ObjectDelete(0, LBL_SL);
   ObjectDelete(0, LBL_TP);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Re-verificación silenciosa cada 12 horas (solo si no es admin)
   static datetime last_lic_check = 0;

   // Heartbeat periódico QuantCore
   if(g_licencia_ok)
   {
      datetime _now = TimeCurrent();
      if(_now - g_last_heartbeat >= HeartbeatInterval)
      {
         g_last_heartbeat = _now;
         if(!SendHeartbeat())
         {
            Print("QuantCore: Heartbeat rechazado. El EA se detiene.");
            g_licencia_ok = false;
            ExpertRemove();
            return;
         }
      }
   }

   if(!is_pending) {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ObjectMove(0, LINE_ENTRY, 0, 0, bid);
   }
   CheckDayReset();
   if(pf_enabled)    CheckPropFirm();
   if(be_enabled)    DoAutoBreakeven();
   if(trail_enabled) DoTrailingStop();
   UpdateCalculations(false);
   UpdateLabels();
   if(show_propfirm) UpdatePropFirmDisplay();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!is_pending) {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ObjectMove(0, LINE_ENTRY, 0, 0, bid);
   }
   CheckDayReset();
   if(pf_enabled)    CheckPropFirm();
   if(be_enabled)    DoAutoBreakeven();
   if(trail_enabled) DoTrailingStop();
   UpdateCalculations(false);
   UpdateLabels();
   if(show_propfirm) UpdatePropFirmDisplay();
}

//+------------------------------------------------------------------+
//| OnChartEvent                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Arrastre del panel
   if(id == CHARTEVENT_OBJECT_DRAG && drag_enabled && 
      (sparam == PANEL_PREFIX+"BG" || sparam == PANEL_PREFIX+"Header")) 
   {
      panel_x = (int)ObjectGetInteger(0, PANEL_PREFIX+"BG", OBJPROP_XDISTANCE);
      panel_y = (int)ObjectGetInteger(0, PANEL_PREFIX+"BG", OBJPROP_YDISTANCE);
      DrawPanel();
      UpdateCalculations(false);
   }
   
   // Fin de edición de campos
   if(id == CHARTEVENT_OBJECT_ENDEDIT) {
      if(sparam == PANEL_PREFIX+"Lot_Edit")  UpdateCalculations(true);
      if(sparam == PANEL_PREFIX+"Risk_Edit") UpdateCalculations(false);
      if(sparam == PANEL_PREFIX+"PF_Edit_DD") {
         user_max_daily_dd = StringToDouble(ObjectGetString(0, sparam, OBJPROP_TEXT));
         if(user_max_daily_dd <= 0) user_max_daily_dd = 0.1;
      }
      if(sparam == PANEL_PREFIX+"PF_Edit_TDD") {
         user_max_total_dd = StringToDouble(ObjectGetString(0, sparam, OBJPROP_TEXT));
         if(user_max_total_dd <= 0) user_max_total_dd = 0.1;
      }
      if(sparam == PANEL_PREFIX+"PF_Edit_TGT") {
         user_daily_target = StringToDouble(ObjectGetString(0, sparam, OBJPROP_TEXT));
         if(user_daily_target <= 0) user_daily_target = 0.1;
      }
      UpdatePropFirmDisplay();
   }
   
   // Arrastre de líneas
   if(id == CHARTEVENT_OBJECT_DRAG && (sparam == LINE_ENTRY || sparam == LINE_SL || sparam == LINE_TP)) {
      UpdateCalculations(false);
      UpdateLabels();
   }
   
   // Cambio de zoom
   if(id == CHARTEVENT_CHART_CHANGE) {
      UpdateLabels();
   }
   
   // Clic en botones
   if(id == CHARTEVENT_OBJECT_CLICK) {
      HandleButtonClick(sparam);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| MANEJADOR DE CLICS                                               |
//+------------------------------------------------------------------+
void HandleButtonClick(string sp)
{
   // Botón de CERRAR EA (X)
   if(sp == PANEL_PREFIX+"Btn_CloseEA") {
      ExpertRemove();
      return;
   }
   // Botón de minimizar
   if(sp == PANEL_PREFIX+"Btn_Minimize") {
      panel_minimized = !panel_minimized;
      DrawPanel();
      return;
   }
   // Botón de arrastre toggle
   if(sp == PANEL_PREFIX+"Btn_Drag") {
      drag_enabled = !drag_enabled;
      color btn_color = drag_enabled ? CLR_ACCENT : CLR_TOGGLE_OFF;
      ObjectSetInteger(0, PANEL_PREFIX+"Btn_Drag", OBJPROP_BGCOLOR, btn_color);
      return;
   }
   
   if(panel_minimized) return;
   
   // Sección EJECUCIÓN
   if(sp == PANEL_PREFIX+"Btn_ExecSection") {
      show_exec = !show_exec;
      DrawPanel();
      return;
   }
   
   if(show_exec) {
      if(sp == PANEL_PREFIX+"Btn_Exec") {
         if(g_trade_block) {
            Alert("Trading bloqueado por Prop Firm: " + g_block_reason);
            return;
         }
         double p_ent = ObjectGetDouble(0, LINE_ENTRY, OBJPROP_PRICE);
         double p_sl  = use_sl ? ObjectGetDouble(0, LINE_SL, OBJPROP_PRICE) : 0;
         double p_tp  = use_tp ? ObjectGetDouble(0, LINE_TP, OBJPROP_PRICE) : 0;
         double lot   = StringToDouble(ObjectGetString(0, PANEL_PREFIX+"Lot_Edit", OBJPROP_TEXT));
         trade.SetTypeFillingBySymbol(_Symbol);
         if(p_tp > p_ent || (!use_tp && !use_sl))
            trade.Buy(lot, _Symbol, (is_pending ? p_ent : 0), p_sl, p_tp, "Javier RM");
         else
            trade.Sell(lot, _Symbol, (is_pending ? p_ent : 0), p_sl, p_tp, "Javier RM");
      }
      if(sp == PANEL_PREFIX+"Btn_Close") CloseAll();
      if(sp == PANEL_PREFIX+"Btn_SL") {
         use_sl = !use_sl;
         ShowHideLine(LINE_SL, use_sl);
         if(!use_sl) ObjectDelete(0, LBL_SL);
         DrawPanel(); UpdateCalculations(false); UpdateLabels();
      }
      if(sp == PANEL_PREFIX+"Btn_TP") {
         use_tp = !use_tp;
         ShowHideLine(LINE_TP, use_tp);
         if(!use_tp) ObjectDelete(0, LBL_TP);
         DrawPanel(); UpdateCalculations(false); UpdateLabels();
      }
      if(sp == PANEL_PREFIX+"Btn_Pend") {
         is_pending = !is_pending;
         DrawPanel(); UpdateCalculations(false);
      }
   }
   
   // Riesgo modo %
   if(sp == PANEL_PREFIX+"Btn_Perc") { is_percent = true;  DrawPanel(); UpdateCalculations(false); }
   if(sp == PANEL_PREFIX+"Btn_Cash") { is_percent = false; DrawPanel(); UpdateCalculations(false); }
   
   // Utilidades
   if(sp == PANEL_PREFIX+"Btn_Utils") {
      show_utils = !show_utils;
      DrawPanel();
   }
   if(show_utils) {
      if(sp == PANEL_PREFIX+"Btn_BE") { be_enabled = !be_enabled; DrawPanel(); }
      if(sp == PANEL_PREFIX+"Btn_Trail") { trail_enabled = !trail_enabled; DrawPanel(); }
      if(sp == PANEL_PREFIX+"Btn_MoveAll") {
         double pip = GetPip();
         double offset = InpBEOffset * pip;
         for(int i=0; i<PositionsTotal(); i++) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            double open = PositionGetDouble(POSITION_PRICE_OPEN);
            double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
            double tp   = PositionGetDouble(POSITION_TP);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY && cur > open)
               trade.PositionModify(t, open+offset, tp);
            else if(type == POSITION_TYPE_SELL && cur < open)
               trade.PositionModify(t, open-offset, tp);
         }
      }
      if(sp == PANEL_PREFIX+"Btn_CloseWin")  CloseWinners();
      if(sp == PANEL_PREFIX+"Btn_CloseLoss") CloseLosers();
   }
   
   // Prop Firm
   if(sp == PANEL_PREFIX+"Btn_PF") {
      show_propfirm = !show_propfirm;
      DrawPanel();
   }
   if(show_propfirm) {
      if(sp == PANEL_PREFIX+"PF_Enable") { pf_enabled = !pf_enabled; DrawPanel(); }
      if(sp == PANEL_PREFIX+"PF_DD")     { pf_daily_dd = !pf_daily_dd; DrawPanel(); }
      if(sp == PANEL_PREFIX+"PF_TDD")    { pf_total_dd = !pf_total_dd; DrawPanel(); }
      if(sp == PANEL_PREFIX+"PF_TGT")    { pf_daily_tgt = !pf_daily_tgt; DrawPanel(); }
      if(sp == PANEL_PREFIX+"PF_MAXP")   { pf_max_pos = !pf_max_pos; DrawPanel(); }
      if(sp == PANEL_PREFIX+"PF_AUTO")   { pf_autoclose = !pf_autoclose; DrawPanel(); }
      if(sp == PANEL_PREFIX+"PF_LOCK")   { pf_lock_tgt = !pf_lock_tgt; DrawPanel(); }
   }
}

//+------------------------------------------------------------------+
//| DRAW PANEL (con botón de cierre X)                               |
//+------------------------------------------------------------------+
void DrawPanel()
{
   if(ObjectFind(0, PANEL_PREFIX+"BG") >= 0) {
      panel_x = (int)ObjectGetInteger(0, PANEL_PREFIX+"BG", OBJPROP_XDISTANCE);
      panel_y = (int)ObjectGetInteger(0, PANEL_PREFIX+"BG", OBJPROP_YDISTANCE);
   }
   ObjectsDeleteAll(0, PANEL_PREFIX);
   
   const int W = 230;
   const int PAD = 10;
   const int BH = 24;
   const int RH = 18;
   const int HEADER_H = 34;
   
   int H;
   if(panel_minimized) {
      H = HEADER_H;
   } else {
      H = HEADER_H + 4;
      H += RH*4 + 12;
      H += 8;
      H += RH + 6;
      H += RH + 6;
      H += RH*2 + 6;
      H += 8;
      // Sección Ejecución
      H += BH + 6;
      if(show_exec) {
         H += BH + 6;
         H += BH + 6;
         H += 30 + 6;
         H += BH + 6;
      }
      // Utilidades
      H += BH + 6;
      if(show_utils) {
         H += BH + 6;
         H += BH + 6;
         H += BH + 6;
      }
      // Prop Firm
      H += BH + 6;
      if(show_propfirm) {
         H += BH + 6;
         H += 20*6 + 8;
         H += RH*3 + 6;
         H += RH + 8;
      }
      H += 20;
   }
   
   int x = panel_x, y = panel_y;
   
   CreateRect(PANEL_PREFIX+"BG", x, y, W, H, CLR_BG, drag_enabled, true);
   CreateRect(PANEL_PREFIX+"ACBAR", x, y, 3, H, CLR_BORDER);
   CreateRect(PANEL_PREFIX+"Header", x, y, W, HEADER_H, CLR_DARK, drag_enabled);
   CreateLabel(PANEL_PREFIX+"T1", x+10, y+5, "RISK MANAGER PRO", 10, clrWhite);
   CreateLabel(PANEL_PREFIX+"T2", x+10, y+21, "VISUAL PRO v13.5", 7, CLR_ACCENT);
   
   CreateBtn(PANEL_PREFIX+"Btn_Minimize", x+W-72, y+4, 20, 16, panel_minimized?"□":"—", CLR_ACCENT, clrBlack);
   CreateBtn(PANEL_PREFIX+"Btn_Drag", x+W-50, y+4, 20, 16, "⋮⋮", drag_enabled?CLR_ACCENT:CLR_TOGGLE_OFF, clrBlack);
   CreateBtn(PANEL_PREFIX+"Btn_CloseEA", x+W-28, y+4, 20, 16, "✕", CLR_CLOSE, clrWhite);
   
   if(panel_minimized) {
      ChartRedraw();
      return;
   }
   
   int cy = y + HEADER_H + 4;
   
   // SECCIÓN CUENTA
   CreateRect(PANEL_PREFIX+"S_ACC", x+3, cy, W-6, 14, CLR_SECTION);
   CreateLabel(PANEL_PREFIX+"SL_ACC", x+PAD, cy+2, "CUENTA", 7, C'70,90,160');
   cy += 16;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double flt = eq - bal;
   double daypnl = eq - g_day_start;
   int rx = x+W-PAD;
   CreateLabel(PANEL_PREFIX+"A_BL", x+PAD, cy+1, "Balance:", 8, C'90,110,170');
   CreateLabel(PANEL_PREFIX+"A_BV", rx, cy+1, DoubleToString(bal,2)+" USD", 8, clrWhite, true);
   cy += RH;
   CreateLabel(PANEL_PREFIX+"A_EL", x+PAD, cy+1, "Equity:", 8, C'90,110,170');
   CreateLabel(PANEL_PREFIX+"A_EV", rx, cy+1, DoubleToString(eq,2)+" USD", 8, clrWhite, true);
   cy += RH;
   CreateLabel(PANEL_PREFIX+"A_FL", x+PAD, cy+1, "Float P&L:", 8, C'90,110,170');
   CreateLabel(PANEL_PREFIX+"A_FV", rx, cy+1, (flt>=0?"+":"")+DoubleToString(flt,2)+" USD", 8, flt>=0?clrLime:clrRed, true);
   cy += RH;
   CreateLabel(PANEL_PREFIX+"A_DL", x+PAD, cy+1, "Hoy P&L:", 8, C'90,110,170');
   CreateLabel(PANEL_PREFIX+"A_DV", rx, cy+1, (daypnl>=0?"+":"")+DoubleToString(daypnl,2)+" USD", 8, daypnl>=0?clrLime:clrRed, true);
   cy += RH+4;
   CreateRect(PANEL_PREFIX+"SEP1", x+5, cy, W-10, 1, C'18,32,75');
   cy += 6;
   
   // RIESGO
   CreateRect(PANEL_PREFIX+"S_RSK", x+3, cy, W-6, 14, CLR_SECTION);
   CreateLabel(PANEL_PREFIX+"SL_RSK", x+PAD, cy+2, "CALCULADORA DE RIESGO", 7, C'70,90,160');
   cy += 16;
   CreateLabel(PANEL_PREFIX+"LR", x+PAD, cy+3, "Risk:", 8, clrLightGray);
   CreateEdit(PANEL_PREFIX+"Risk_Edit", x+46, cy, 52, 19, DoubleToString(risk_val,1), clrWhite, clrBlack);
   CreateBtn(PANEL_PREFIX+"Btn_Perc", x+104, cy, 50, 19, "%", is_percent?CLR_ACCENT:CLR_TOGGLE_OFF, is_percent?clrBlack:clrWhite);
   CreateBtn(PANEL_PREFIX+"Btn_Cash", x+158, cy, 52, 19, "$", !is_percent?CLR_ACCENT:CLR_TOGGLE_OFF, !is_percent?clrBlack:clrWhite);
   cy += RH+4;
   CreateLabel(PANEL_PREFIX+"LL", x+PAD, cy+3, "Lotes:", 8, clrLightGray);
   CreateEdit(PANEL_PREFIX+"Lot_Edit", x+54, cy, 96, 19, "0.01", CLR_ACCENT, clrBlack);
   cy += RH+4;
   CreateLabel(PANEL_PREFIX+"LW", x+PAD, cy, "GANAR:", 8, clrLime);
   CreateLabel(PANEL_PREFIX+"Val_Win", x+66, cy, "0.00 USD", 8, clrWhite);
   cy += RH-2;
   CreateLabel(PANEL_PREFIX+"LL2", x+PAD, cy, "PERDER:", 8, clrRed);
   CreateLabel(PANEL_PREFIX+"Val_Loss", x+66, cy, "0.00 USD", 8, clrWhite);
   cy += RH+4;
   CreateRect(PANEL_PREFIX+"SEP2", x+5, cy, W-10, 1, C'18,32,75');
   cy += 6;
   
   // SECCIÓN EJECUCIÓN (órdenes)
   CreateBtn(PANEL_PREFIX+"Btn_ExecSection", x+PAD, cy, W-PAD*2, BH, show_exec?"▲  EJECUCIÓN":"▼  EJECUCIÓN", CLR_EXEC);
   cy += BH+6;
   if(show_exec) {
      int hw = (W-PAD*2-4)/2;
      CreateBtn(PANEL_PREFIX+"Btn_SL", x+PAD, cy, hw, BH, use_sl?"SL  ON":"SL  OFF", use_sl?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateBtn(PANEL_PREFIX+"Btn_TP", x+PAD+hw+4, cy, hw, BH, use_tp?"TP  ON":"TP  OFF", use_tp?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      cy += BH+6;
      CreateBtn(PANEL_PREFIX+"Btn_Pend", x+PAD, cy, W-PAD*2, BH, "ORDEN PENDIENTE", is_pending?CLR_ACCENT:clrDarkSlateGray, is_pending?clrBlack:clrWhite);
      cy += BH+6;
      CreateBtn(PANEL_PREFIX+"Btn_Exec", x+PAD, cy, W-PAD*2, 30, "EXECUTE BUY", CLR_BUY);
      cy += 30+6;
      CreateBtn(PANEL_PREFIX+"Btn_Close", x+PAD, cy, W-PAD*2, BH, "✖  CLOSE ALL", CLR_SELL);
      cy += BH+6;
   }
   
   // UTILIDADES
   CreateBtn(PANEL_PREFIX+"Btn_Utils", x+PAD, cy, W-PAD*2, BH, show_utils?"▲  UTILIDADES":"▼  UTILIDADES", CLR_UTILS);
   cy += BH+6;
   if(show_utils) {
      int hw = (W-PAD*2-4)/2;
      CreateBtn(PANEL_PREFIX+"Btn_BE", x+PAD, cy, hw, BH, be_enabled?"🔒 BE: ON":"BE: OFF", be_enabled?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateBtn(PANEL_PREFIX+"Btn_Trail", x+PAD+hw+4, cy, hw, BH, trail_enabled?"📈 TRAIL: ON":"TRAIL: OFF", trail_enabled?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      cy += BH+6;
      CreateBtn(PANEL_PREFIX+"Btn_MoveAll", x+PAD, cy, W-PAD*2, BH, "⚡ MOVE ALL TO BREAKEVEN", C'14,38,80');
      cy += BH+6;
      CreateBtn(PANEL_PREFIX+"Btn_CloseWin", x+PAD, cy, hw, BH, "✔ WINNERS", C'0,68,34');
      CreateBtn(PANEL_PREFIX+"Btn_CloseLoss", x+PAD+hw+4, cy, hw, BH, "✘ LOSERS", C'78,18,18');
      cy += BH+6;
   }
   CreateRect(PANEL_PREFIX+"SEP4", x+5, cy, W-10, 1, C'18,32,75');
   cy += 6;
   
   // PROP FIRM
   color pf_hdr = pf_enabled?C'0,46,95':C'8,20,70';
   CreateBtn(PANEL_PREFIX+"Btn_PF", x+PAD, cy, W-PAD*2, BH, (show_propfirm?"▲":"▼")+"  PROP FIRM PROTECTION", pf_hdr);
   cy += BH+6;
   if(show_propfirm) {
      CreateBtn(PANEL_PREFIX+"PF_Enable", x+PAD, cy, W-PAD*2, BH, pf_enabled?"⚡ PROP FIRM: ACTIVO":"○ PROP FIRM: INACTIVO", pf_enabled?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      cy += BH+4;
      const int TW = 34, TH = 18;
      // Daily DD
      CreateBtn(PANEL_PREFIX+"PF_DD", x+PAD, cy, TW, TH, pf_daily_dd?"ON":"OFF", pf_daily_dd?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateLabel(PANEL_PREFIX+"PFL_DD", x+PAD+TW+4, cy+2, "Daily DD Max", 8, clrLightGray);
      CreateEdit(PANEL_PREFIX+"PF_Edit_DD", rx-40, cy, 40, TH, DoubleToString(user_max_daily_dd,1), clrWhite, clrBlack);
      cy += 20;
      // Total DD
      CreateBtn(PANEL_PREFIX+"PF_TDD", x+PAD, cy, TW, TH, pf_total_dd?"ON":"OFF", pf_total_dd?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateLabel(PANEL_PREFIX+"PFL_TDD", x+PAD+TW+4, cy+2, "Total DD Max", 8, clrLightGray);
      CreateEdit(PANEL_PREFIX+"PF_Edit_TDD", rx-40, cy, 40, TH, DoubleToString(user_max_total_dd,1), clrWhite, clrBlack);
      cy += 20;
      // Daily Target
      CreateBtn(PANEL_PREFIX+"PF_TGT", x+PAD, cy, TW, TH, pf_daily_tgt?"ON":"OFF", pf_daily_tgt?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateLabel(PANEL_PREFIX+"PFL_TGT", x+PAD+TW+4, cy+2, "Daily Target", 8, clrLightGray);
      CreateEdit(PANEL_PREFIX+"PF_Edit_TGT", rx-40, cy, 40, TH, DoubleToString(user_daily_target,1), clrLime, clrBlack);
      cy += 20;
      // Max posiciones
      CreateBtn(PANEL_PREFIX+"PF_MAXP", x+PAD, cy, TW, TH, pf_max_pos?"ON":"OFF", pf_max_pos?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateLabel(PANEL_PREFIX+"PFL_MAXP", x+PAD+TW+4, cy+2, "Max Posiciones", 8, clrLightGray);
      CreateLabel(PANEL_PREFIX+"PFV_MAXP", rx, cy+2, IntegerToString(InpMaxPositions), 8, clrWhite, true);
      cy += 20;
      // Auto-close
      CreateBtn(PANEL_PREFIX+"PF_AUTO", x+PAD, cy, TW, TH, pf_autoclose?"ON":"OFF", pf_autoclose?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateLabel(PANEL_PREFIX+"PFL_AUTO", x+PAD+TW+4, cy+2, "Auto-close DD", 8, clrLightGray);
      CreateLabel(PANEL_PREFIX+"PFV_AUTO", rx, cy+2, pf_autoclose?"✔":"✘", 8, pf_autoclose?clrLime:clrRed, true);
      cy += 20;
      // Lock target
      CreateBtn(PANEL_PREFIX+"PF_LOCK", x+PAD, cy, TW, TH, pf_lock_tgt?"ON":"OFF", pf_lock_tgt?CLR_TOGGLE_ON:CLR_TOGGLE_OFF);
      CreateLabel(PANEL_PREFIX+"PFL_LOCK", x+PAD+TW+4, cy+2, "Lock al target", 8, clrLightGray);
      CreateLabel(PANEL_PREFIX+"PFV_LOCK", rx, cy+2, pf_lock_tgt?"SI":"NO", 8, pf_lock_tgt?clrYellow:C'80,80,80', true);
      cy += 24;
      // Barras de progreso
      CreateLabel(PANEL_PREFIX+"PF_BAR_DD",  x+PAD, cy, "DD:  ░░░░░░░░░░ 0.00%", 7, clrLime);
      cy += RH-2;
      CreateLabel(PANEL_PREFIX+"PF_BAR_TDD", x+PAD, cy, "TDD: ░░░░░░░░░░ 0.00%", 7, clrLime);
      cy += RH-2;
      CreateLabel(PANEL_PREFIX+"PF_BAR_TGT", x+PAD, cy, "TGT: ░░░░░░░░░░ 0.00%", 7, clrLime);
      cy += RH+2;
      CreateLabel(PANEL_PREFIX+"PF_STATUS", x+PAD, cy, "Status: ✔ ACTIVO", 8, clrLime);
      UpdatePropFirmDisplay();
   }
   
   UpdateCalculations(false);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| ACTUALIZAR DISPLAY PROP FIRM                                     |
//+------------------------------------------------------------------+
void UpdatePropFirmDisplay()
{
   if(!show_propfirm) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_max_eq_day) g_max_eq_day = eq;
   double ddd  = g_day_start>0 ? (g_max_eq_day-eq)/g_day_start*100.0 : 0;
   double tdd  = g_start_bal>0 ? MathMax(0,(g_start_bal-eq)/g_start_bal*100.0) : 0;
   double dpft = g_day_start>0 ? (eq-g_day_start)/g_day_start*100.0 : 0;
   
   color c_dd  = ddd>=user_max_daily_dd ? clrRed : (ddd>=user_max_daily_dd*0.7?clrYellow:clrLime);
   color c_tdd = tdd>=user_max_total_dd ? clrRed : (tdd>=user_max_total_dd*0.7?clrYellow:clrLime);
   color c_tgt = dpft>=user_daily_target*0.5 ? clrLime : clrWhite;
   
   ObjectSetString(0, PANEL_PREFIX+"PF_BAR_DD", OBJPROP_TEXT, "DD:  " + ProgBar(ddd, user_max_daily_dd) + StringFormat(" %.2f%%", ddd));
   ObjectSetInteger(0, PANEL_PREFIX+"PF_BAR_DD", OBJPROP_COLOR, c_dd);
   ObjectSetString(0, PANEL_PREFIX+"PF_BAR_TDD", OBJPROP_TEXT, "TDD: " + ProgBar(tdd, user_max_total_dd) + StringFormat(" %.2f%%", tdd));
   ObjectSetInteger(0, PANEL_PREFIX+"PF_BAR_TDD", OBJPROP_COLOR, c_tdd);
   ObjectSetString(0, PANEL_PREFIX+"PF_BAR_TGT", OBJPROP_TEXT, "TGT: " + ProgBar(dpft, user_daily_target) + StringFormat(" %.2f%%", dpft));
   ObjectSetInteger(0, PANEL_PREFIX+"PF_BAR_TGT", OBJPROP_COLOR, c_tgt);
   
   string st; color sc;
   if(g_trade_block) { st = "⛔ BLOQUEADO – "+g_block_reason; sc = clrRed; }
   else if(dpft>=user_daily_target && pf_lock_tgt && pf_daily_tgt) { st = "🔒 TARGET ALCANZADO"; sc = clrLime; }
   else { st = "✔ ACTIVO"; sc = clrLime; }
   ObjectSetString(0, PANEL_PREFIX+"PF_STATUS", OBJPROP_TEXT, "Status: "+st);
   ObjectSetInteger(0, PANEL_PREFIX+"PF_STATUS", OBJPROP_COLOR, sc);
}

//+------------------------------------------------------------------+
//| AUTO BREAKEVEN                                                   |
//+------------------------------------------------------------------+
void DoAutoBreakeven()
{
   if(!be_enabled) return;
   double pip = GetPip();
   double actDist = InpBEActivate * pip;
   double offDist = InpBEOffset * pip;
   for(int i=0; i<PositionsTotal(); i++) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY) {
         if((cur-open) >= actDist && sl < open+offDist)
            trade.PositionModify(t, open+offDist, tp);
      } else {
         if((open-cur) >= actDist && (sl > open-offDist || sl==0))
            trade.PositionModify(t, open-offDist, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| TRAILING STOP                                                    |
//+------------------------------------------------------------------+
void DoTrailingStop()
{
   if(!trail_enabled) return;
   double pip = GetPip();
   double actDist = InpTSActivate * pip;
   double trailDst = InpTSDistance * pip;
   double stepDst = InpTSStep * pip;
   for(int i=0; i<PositionsTotal(); i++) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY) {
         if((cur-open) < actDist) continue;
         double idealSL = cur - trailDst;
         if(idealSL > sl + stepDst)
            trade.PositionModify(t, idealSL, tp);
      } else {
         if((open-cur) < actDist) continue;
         double idealSL = cur + trailDst;
         if(sl==0 || idealSL < sl - stepDst)
            trade.PositionModify(t, idealSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK PROP FIRM                                                  |
//+------------------------------------------------------------------+
void CheckPropFirm()
{
   if(!pf_enabled) { g_trade_block=false; g_block_reason=""; return; }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_max_eq_day) g_max_eq_day = eq;
   double ddd  = g_day_start>0 ? (g_max_eq_day-eq)/g_day_start*100.0 : 0;
   double tdd  = g_start_bal>0 ? MathMax(0,(g_start_bal-eq)/g_start_bal*100.0) : 0;
   double dpft = g_day_start>0 ? (eq-g_day_start)/g_day_start*100.0 : 0;
   g_trade_block = false;
   g_block_reason = "";
   if(pf_daily_dd && ddd >= user_max_daily_dd) {
      g_trade_block = true; g_block_reason = "Daily DD";
      if(pf_autoclose && PositionsTotal()>0) { CloseAll(); Alert("⛔ PROP FIRM: Daily DD alcanzado"); }
      return;
   }
   if(pf_total_dd && tdd >= user_max_total_dd) {
      g_trade_block = true; g_block_reason = "Total DD";
      if(pf_autoclose && PositionsTotal()>0) { CloseAll(); Alert("⛔ PROP FIRM: Total DD alcanzado"); }
      return;
   }
   if(pf_max_pos && PositionsTotal() >= InpMaxPositions) {
      g_trade_block = true; g_block_reason = "Máx Posiciones";
   }
   if(pf_daily_tgt && pf_lock_tgt && dpft >= user_daily_target && !g_pf_locked) {
      g_pf_locked = true; g_trade_block = true; g_block_reason = "Target Diario Alcanzado";
   }
}

//+------------------------------------------------------------------+
//| RESET DIARIO                                                     |
//+------------------------------------------------------------------+
void CheckDayReset()
{
   MqlDateTime now, last;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(g_last_reset, last);
   if(now.day != last.day) {
      g_day_start = AccountInfoDouble(ACCOUNT_BALANCE);
      g_max_eq_day = AccountInfoDouble(ACCOUNT_EQUITY);
      g_last_reset = TimeCurrent();
      g_pf_locked = false;
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL, WINNERS, LOSERS                                       |
//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL)==_Symbol)
         trade.PositionClose(t);
   }
}
void CloseWinners()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetDouble(POSITION_PROFIT)>0)
         trade.PositionClose(t);
   }
}
void CloseLosers()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetDouble(POSITION_PROFIT)<0)
         trade.PositionClose(t);
   }
}

//+------------------------------------------------------------------+
//| CÁLCULO DE LOTE                                                  |
//+------------------------------------------------------------------+
void UpdateCalculations(bool lot_was_edited)
{
   risk_val = StringToDouble(ObjectGetString(0, PANEL_PREFIX+"Risk_Edit", OBJPROP_TEXT));
   double input_lot = StringToDouble(ObjectGetString(0, PANEL_PREFIX+"Lot_Edit", OBJPROP_TEXT));
   double p_ent = ObjectGetDouble(0, LINE_ENTRY, OBJPROP_PRICE);
   double p_sl  = ObjectGetDouble(0, LINE_SL, OBJPROP_PRICE);
   double p_tp  = ObjectGetDouble(0, LINE_TP, OBJPROP_PRICE);
   double diff_sl = use_sl ? MathAbs(p_ent-p_sl) : 0;
   double diff_tp = use_tp ? MathAbs(p_ent-p_tp) : 0;
   
   if(!use_sl || diff_sl<=0) {
      if(!lot_was_edited)
         ObjectSetString(0, PANEL_PREFIX+"Lot_Edit", OBJPROP_TEXT, DoubleToString(input_lot>0?input_lot:0.01,2));
      ObjectSetString(0, PANEL_PREFIX+"Val_Loss", OBJPROP_TEXT, "SIN SL");
      double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double money_win = use_tp ? (diff_tp/tick_size)*tick_val*input_lot : 0;
      ObjectSetString(0, PANEL_PREFIX+"Val_Win", OBJPROP_TEXT, use_tp?("+"+DoubleToString(money_win,2)+" USD"):"SIN TP");
      bool is_buy = (p_tp>p_ent);
      ObjectSetString(0, PANEL_PREFIX+"Btn_Exec", OBJPROP_TEXT, (is_pending?"LIMIT ":"EXECUTE ")+(is_buy?"BUY":"SELL"));
      ObjectSetInteger(0, PANEL_PREFIX+"Btn_Exec", OBJPROP_BGCOLOR, is_buy?CLR_BUY:CLR_SELL);
      return;
   }
   
   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double final_lot=0;
   if(lot_was_edited) final_lot = input_lot;
   else {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk_money = is_percent ? balance*risk_val/100.0 : risk_val;
      if(risk_money<=0 || (diff_sl/tick_size*tick_val)<=0) final_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      else final_lot = risk_money / ((diff_sl/tick_size)*tick_val);
   }
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   final_lot = MathFloor(final_lot/step)*step;
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(final_lot<min_lot) final_lot=min_lot;
   if(final_lot>max_lot) final_lot=max_lot;
   
   double money_loss = (diff_sl/tick_size)*tick_val*final_lot;
   double money_win = use_tp ? (diff_tp/tick_size)*tick_val*final_lot : 0;
   if(!lot_was_edited)
      ObjectSetString(0, PANEL_PREFIX+"Lot_Edit", OBJPROP_TEXT, DoubleToString(final_lot,2));
   ObjectSetString(0, PANEL_PREFIX+"Val_Loss", OBJPROP_TEXT, "-"+DoubleToString(money_loss,2)+" USD");
   ObjectSetString(0, PANEL_PREFIX+"Val_Win", OBJPROP_TEXT, use_tp?("+"+DoubleToString(money_win,2)+" USD"):"SIN TP");
   bool is_buy = (p_tp>p_ent);
   ObjectSetString(0, PANEL_PREFIX+"Btn_Exec", OBJPROP_TEXT, (is_pending?"LIMIT ":"EXECUTE ")+(is_buy?"BUY":"SELL"));
   ObjectSetInteger(0, PANEL_PREFIX+"Btn_Exec", OBJPROP_BGCOLOR, is_buy?CLR_BUY:CLR_SELL);
}

//+------------------------------------------------------------------+
//| FUNCIONES AUXILIARES                                             |
//+------------------------------------------------------------------+
void ShowHideLine(string name, bool visible)
{
   if(ObjectFind(0,name)<0) return;
   if(visible) {
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   } else {
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   }
}
void CreateLine(string n, color c, double p)
{
   ObjectCreate(0,n,OBJ_HLINE,0,0,p);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,n,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,true);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
}
void CreateRect(string n, int x, int y, int w, int h, color c, bool sel=false, bool border=false)
{
   ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,c);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,border?BORDER_SUNKEN:BORDER_FLAT);
   if(border) ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,CLR_BORDER);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,sel);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
void CreateBtn(string n, int x, int y, int w, int h, string t, color bg, color txt=clrWhite)
{
   ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,t);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,txt);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
void CreateLabel(string n, int x, int y, string t, int s, color c, bool right=false)
{
   ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,n,OBJPROP_TEXT,t);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,s);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,right?ANCHOR_RIGHT_UPPER:ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
void CreateEdit(string n, int x, int y, int w, int h, string t, color bg, color txt)
{
   ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,t);
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,txt);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
double GetPip()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return point * ((digits==3||digits==5)?10.0:1.0);
}
string ProgBar(double val, double maxVal, int bars=10)
{
   int filled = (maxVal>0) ? (int)MathRound((val/maxVal)*bars) : 0;
   filled = MathMax(0, MathMin(bars, filled));
   string s="";
   for(int i=0; i<filled; i++) s+="█";
   for(int i=filled; i<bars; i++) s+="░";
   return s;
}
//+------------------------------------------------------------------+