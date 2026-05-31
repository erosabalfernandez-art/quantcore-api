//+------------------------------------------------------------------+
//|         Samtrader Backtest Simulator Pro  v4.2                   |
//|         Copyright 2026, Javier Trader                            |
//|                                                                  |
//|  v4.2 – Fixes aplicados:                                        |
//|  • [FIX 1] Botones nunca bloqueados por líneas TV               |
//|            (z-order panel >> z-order líneas)                    |
//|  • [FIX 2] Panel y línea roja se mueven de forma independiente  |
//|  • [FIX 3] Máscara nunca oculta el panel (z-order corregido)   |
//|  • [FIX 4] EA no se desbarata al hacer scroll con la rueda     |
//|  • [FIX 5] EA mantiene su posición al cambiar temporalidad     |
//|                                                                  |
//|  Funcionalidad original intacta.                                |
//+------------------------------------------------------------------+
#property copyright "Javier Trader"
#property version   "4.20"

#include <Trade\Trade.mqh>

//══════════════════════════════════════════════════════════════════
//  INPUTS
//══════════════════════════════════════════════════════════════════
input double  InpInitialBalance = 10000.0;
input double  InpDefaultRiskPct = 1.0;
input int     InpSLPipsDefault  = 100;
input int     InpTPPipsDefault  = 200;

//══════════════════════════════════════════════════════════════════
//  LICENCIA
//══════════════════════════════════════════════════════════════════
//══════════════════════════════════════════════════════════════════
//  BLOQUE DE LICENCIAS — QuantCore (Parte 3)
//  Sin tokens de administrador. Validación 100% vía servidor.
//══════════════════════════════════════════════════════════════════
input string Licencia_Token    = "";                                      // Token de licencia (cópialo de tu perfil en la web)
input string ApiUrl            = "https://TU-PROYECTO.vercel.app/api/";   // URL base de tu despliegue Vercel (incluye / al final)
input int    HeartbeatInterval = 3600;                                     // Segundos entre heartbeats (mín. 600)

#define EA_TIPO "backtest_simulator"

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


//══════════════════════════════════════════════════════════════════
//  PREFIJOS DE OBJETOS
//══════════════════════════════════════════════════════════════════
#define PNL_PFX   "BTP_"
#define CHT_PFX   "BT_"
#define TV_PFX    "TV_"

#define OBJ_ORIGIN   "BT_Origin"
#define OBJ_MASK     "BT_Mask"
#define OBJ_PNL_LBL  "BT_PnLLbl"

#define TV_ENTRY     "TV_Entry"
#define TV_SL        "TV_SL"
#define TV_TP        "TV_TP"
#define TV_ZONE_TP   "TV_ZoneTP"
#define TV_ZONE_SL   "TV_ZoneSL"
#define TV_LBL_TP_BG "TV_Lbl_TP_Bg"
#define TV_LBL_TP_T1 "TV_Lbl_TP_T1"
#define TV_LBL_EN_BG "TV_Lbl_EN_Bg"
#define TV_LBL_EN_T1 "TV_Lbl_EN_T1"
#define TV_LBL_EN_T2 "TV_Lbl_EN_T2"
#define TV_LBL_SL_BG "TV_Lbl_SL_Bg"
#define TV_LBL_SL_T1 "TV_Lbl_SL_T1"

//══════════════════════════════════════════════════════════════════
//  ESTRUCTURA POSICIÓN VIRTUAL
//══════════════════════════════════════════════════════════════════
#define MAX_POS 200
struct VirtualPosition
{
    ulong    id;
    int      type;
    double   volume;
    double   openPrice;
    datetime openTime;
    double   sl;
    double   tp;
    double   closePrice;
    datetime closeTime;
    double   profit;
    bool     isClosed;
    string   closeReason;
};

//══════════════════════════════════════════════════════════════════
//  GESTOR DE TRADING VIRTUAL
//══════════════════════════════════════════════════════════════════
class CVirtualTradeManager
{
private:
    VirtualPosition m_pos[MAX_POS];
    int    m_count;
    double m_balance;
    double m_initBal;
    int    m_wins;
    int    m_losses;
    double m_totalHoldSec;
    string m_lastResult;

public:
    void Init(double b)
    {
        m_initBal=b; m_balance=b; m_count=0;
        m_wins=0; m_losses=0; m_totalHoldSec=0; m_lastResult="---";
        ZeroMemory(m_pos);
    }
    void Reset()
    {
        m_balance=m_initBal; m_count=0;
        m_wins=0; m_losses=0; m_totalHoldSec=0; m_lastResult="---";
    }
    int Open(int type, double vol, double sl, double tp, double price, datetime t)
    {
        if(m_count>=MAX_POS) return -1;
        int i=m_count++;
        m_pos[i].id          = (ulong)TimeCurrent()+(ulong)i;
        m_pos[i].type        = type;
        m_pos[i].volume      = vol;
        m_pos[i].openPrice   = price;
        m_pos[i].openTime    = t;
        m_pos[i].sl          = sl;
        m_pos[i].tp          = tp;
        m_pos[i].closePrice  = 0;
        m_pos[i].closeTime   = 0;
        m_pos[i].profit      = 0;
        m_pos[i].isClosed    = false;
        m_pos[i].closeReason = "";
        return i;
    }
    double CalcProfit(int idx, double closePrice)
    {
        if(idx<0||idx>=m_count) return 0;
        double diff=(m_pos[idx].type==0)?(closePrice-m_pos[idx].openPrice):(m_pos[idx].openPrice-closePrice);
        double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
        double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
        return (ts>0) ? diff*m_pos[idx].volume*(tv/ts) : 0;
    }
    void Close(int idx, double closePrice, datetime closeTime, string reason="Manual")
    {
        if(idx<0||idx>=m_count||m_pos[idx].isClosed) return;
        m_pos[idx].closePrice  = closePrice;
        m_pos[idx].closeTime   = closeTime;
        m_pos[idx].closeReason = reason;
        m_pos[idx].profit      = CalcProfit(idx, closePrice);
        m_pos[idx].isClosed    = true;
        m_balance += m_pos[idx].profit;
        if(m_pos[idx].profit>=0)
            { m_wins++;   m_lastResult=reason+"  ✔  +" +DoubleToString(m_pos[idx].profit,2)+" $"; }
        else
            { m_losses++; m_lastResult=reason+"  ✘  " +DoubleToString(m_pos[idx].profit,2)+" $"; }
        m_totalHoldSec += (double)(closeTime - m_pos[idx].openTime);
    }
    void CloseAll(double closePrice, datetime closeTime)
    {
        for(int i=m_count-1;i>=0;i--)
            if(!m_pos[i].isClosed) Close(i,closePrice,closeTime,"Cierre Manual");
    }
    void ModifySLTP(int idx, double newSL, double newTP)
    {
        if(idx<0||idx>=m_count||m_pos[idx].isClosed) return;
        if(newSL>0) m_pos[idx].sl=newSL;
        if(newTP>0) m_pos[idx].tp=newTP;
    }
    bool PartialClose(int idx, double closePrice, datetime closeTime)
    {
        if(idx<0||idx>=m_count||m_pos[idx].isClosed) return false;
        double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
        double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
        double half=MathFloor((m_pos[idx].volume*0.5)/step)*step;
        if(half<minLot){ Close(idx,closePrice,closeTime,"Cierre 50%"); return true; }
        double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
        double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
        double diff=(m_pos[idx].type==0)?(closePrice-m_pos[idx].openPrice):(m_pos[idx].openPrice-closePrice);
        m_balance += (ts>0)?diff*half*(tv/ts):0;
        m_pos[idx].volume -= half;
        return false;
    }
    int    GetOpenIndex()  { for(int i=m_count-1;i>=0;i--) if(!m_pos[i].isClosed) return i; return -1; }
    bool   GetPosition(int idx, VirtualPosition &p) { if(idx<0||idx>=m_count) return false; p=m_pos[idx]; return true; }
    double GetBalance()    { return m_balance; }
    double GetInitBal()    { return m_initBal; }
    int    GetWins()       { return m_wins; }
    int    GetLosses()     { return m_losses; }
    string GetLastResult() { return m_lastResult; }
    double GetWinRate()    { int t=m_wins+m_losses; return(t>0)?(double)m_wins/t*100.0:0.0; }
};

//══════════════════════════════════════════════════════════════════
//  VARIABLES GLOBALES
//══════════════════════════════════════════════════════════════════
CVirtualTradeManager g_trade;

bool     g_simPaused    = true;
int      g_speedLevel   = 3;
int      g_currentPos   = -1;
int      g_timerTick    = 0;
bool     g_needMaskRefresh = false;
int      g_navigateRetries = 0;       // [FIX 5b] intentos de navegación al cambiar temporalidad
datetime g_savedOriginT   = 0;        // [FIX 5c] datetime del origen guardado explícitamente

// Panel
int      g_panelX       = 15;
int      g_panelY       = 40;
bool     g_panelMin     = false;
bool     g_showStats    = true;
bool     g_showOps      = true;
bool     g_showTV       = false;
bool     g_showTime     = true;
bool     g_showRisk     = true;
bool     g_showPersist  = true;
bool     g_tvLabelsVisible = true;   // [NUEVO] toggle etiquetas TV

// Interfaz TV
int      g_tvZoneW      = 20;

// Arrastre del panel por mouse
int      g_dragMode     = 0;
int      g_dragOffX     = 0;
int      g_dragOffY     = 0;

// [FIX 2] Flag: indica que el usuario está arrastrando la línea de origen
bool     g_originDragging = false;

// [FIX 5] Período anterior para detectar cambio de temporalidad
ENUM_TIMEFRAMES g_lastPeriod = PERIOD_CURRENT;

// Dimensiones panel
#define  PANEL_W  286
#define  PAD      8
#define  BH       26
#define  SH       22
#define  RH       18
#define  EH       20

// Paleta
#define C_BG      C'7,13,34'
#define C_HDR     C'5,9,24'
#define C_SEC     C'12,22,60'
#define C_ACCENT  C'0,188,212'
#define C_GREEN   C'0,200,100'
#define C_RED     C'220,50,50'
#define C_TXT     clrWhite
#define C_TXTS    C'100,130,175'
#define C_BTN     C'18,32,80'
#define C_BTN2    C'22,40,100'

// Colores zonas TV
#define TV_CLR_TP      C'0,170,70'
#define TV_CLR_SL      C'200,45,45'
#define TV_CLR_TP_LBL  C'12,55,28'
#define TV_CLR_SL_LBL  C'70,14,14'
#define TV_CLR_EN_LBL  C'28,20,8'

// ──────────────────────────────────────────────────────────────────
// [FIX 1 / FIX 3]  TABLA DE Z-ORDERS
//
//   Z_TV_ZONE   = 0   rectangulos TV (detrás de velas)
//   Z_MASK      = 1   máscara tapadora de velas
//   Z_TV_LINE   = 2   líneas TV arrastrables (Entry/SL/TP + OBJ_ORIGIN)
//   Z_TV_BOX    = 3   etiquetas TV (fondo)
//   Z_TV_BOXTXT = 4   etiquetas TV (texto)
//   Z_PNL_BG    = 90  fondos del panel
//   Z_PNL_OBJ   = 100 botones / labels / edits del panel
//
//   => El panel SIEMPRE está por encima de la máscara y de las líneas TV.
//   => Las líneas TV están por encima de la máscara pero por DEBAJO del panel.
// ──────────────────────────────────────────────────────────────────
#define Z_TV_ZONE   0
#define Z_MASK      1
#define Z_TV_LINE   2
#define Z_TV_BOX    3
#define Z_TV_BOXTXT 4
#define Z_PNL_BG    90
#define Z_PNL_OBJ   100

#define SAVE_FILE "samtrader_v4_session.dat"

//══════════════════════════════════════════════════════════════════
//  UTILIDADES GENERALES
//══════════════════════════════════════════════════════════════════
double GetPip()
{
    int d=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    return SymbolInfoDouble(_Symbol,SYMBOL_POINT)*((d==3||d==5)?10.0:1.0);
}
double CalcMoney(double priceDiff, double lot)
{
    double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    return (ts>0) ? MathAbs(priceDiff)*lot*(tv/ts) : 0;
}
double CalcLotFromRiskPct(double riskPct, double entryPrice, double slPrice)
{
    double balance   = g_trade.GetBalance();
    double riskMoney = balance * riskPct / 100.0;
    if(riskMoney <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double diff = MathAbs(entryPrice - slPrice);
    if(diff <= 0 || ts <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double valuePerLot = (diff / ts) * tv;
    if(valuePerLot <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double raw    = MathFloor((riskMoney / valuePerLot) / step) * step;
    return MathMax(minLot, MathMin(maxLot, raw));
}
double CalcRiskPctFromLot(double lot, double entryPrice, double slPrice)
{
    double balance = g_trade.GetBalance();
    if(balance <= 0) return 0;
    double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double diff = MathAbs(entryPrice - slPrice);
    if(diff <= 0 || ts <= 0) return 0;
    return ((diff / ts) * tv * lot) / balance * 100.0;
}
double GetLot()
{
    if(ObjectFind(0,PNL_PFX+"Edit_Lot")<0) return 0.10;
    double v=StringToDouble(ObjectGetString(0,PNL_PFX+"Edit_Lot",OBJPROP_TEXT));
    return(v>0)?v:0.10;
}
double GetRiskPct()
{
    if(ObjectFind(0,PNL_PFX+"Edit_RskPct")<0) return InpDefaultRiskPct;
    double v=StringToDouble(ObjectGetString(0,PNL_PFX+"Edit_RskPct",OBJPROP_TEXT));
    return(v>0)?v:InpDefaultRiskPct;
}

//══════════════════════════════════════════════════════════════════
//  HELPERS UI (pixel-based)
//  [FIX 1/3] Z_PNL_BG=90 y Z_PNL_OBJ=100, muy por encima de
//  la máscara (1) y de las líneas TV (2-4).
//══════════════════════════════════════════════════════════════════
void _Rect(string n,int x,int y,int w,int h,color c,int border=BORDER_FLAT,color bc=C'0,188,212')
{
    if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,   x);
    ObjectSetInteger(0,n,OBJPROP_YDISTANCE,   y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,       w);
    ObjectSetInteger(0,n,OBJPROP_YSIZE,       h);
    ObjectSetInteger(0,n,OBJPROP_BGCOLOR,     c);
    ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE, border);
    ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,bc);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,  false);
    ObjectSetInteger(0,n,OBJPROP_HIDDEN,      true);
    ObjectSetInteger(0,n,OBJPROP_CORNER,      CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_ZORDER,      Z_PNL_BG);   // [FIX 1/3]
}
void _Btn(string n,int x,int y,int w,int h,string t,color bg,color fc=clrWhite,int fs=8)
{
    if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE, x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,     w); ObjectSetInteger(0,n,OBJPROP_YSIZE,     h);
    ObjectSetString(0, n,OBJPROP_TEXT,      t); ObjectSetInteger(0,n,OBJPROP_BGCOLOR,   bg);
    ObjectSetInteger(0,n,OBJPROP_COLOR,     fc);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,  fs);
    ObjectSetInteger(0,n,OBJPROP_STATE,    false);
    ObjectSetInteger(0,n,OBJPROP_HIDDEN,   true);
    ObjectSetInteger(0,n,OBJPROP_CORNER,   CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_ZORDER,   Z_PNL_OBJ);   // [FIX 1]
}
void _Lbl(string n,int x,int y,string t,int s,color c,bool right=false)
{
    if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE, x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE, y);
    ObjectSetString(0, n,OBJPROP_TEXT,      t); ObjectSetInteger(0,n,OBJPROP_FONTSIZE,  s);
    ObjectSetInteger(0,n,OBJPROP_COLOR,     c);
    ObjectSetInteger(0,n,OBJPROP_ANCHOR,    right?ANCHOR_RIGHT_UPPER:ANCHOR_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,n,OBJPROP_HIDDEN,    true);
    ObjectSetInteger(0,n,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_ZORDER,    Z_PNL_OBJ);   // [FIX 1]
}
void _Edit(string n,int x,int y,int w,int h,string t,color bg,color fc)
{
    if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_EDIT,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE, x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,     w); ObjectSetInteger(0,n,OBJPROP_YSIZE,     h);
    ObjectSetString(0, n,OBJPROP_TEXT,      t); ObjectSetInteger(0,n,OBJPROP_ALIGN, ALIGN_CENTER);
    ObjectSetInteger(0,n,OBJPROP_BGCOLOR,   bg);ObjectSetInteger(0,n,OBJPROP_COLOR,     fc);
    ObjectSetInteger(0,n,OBJPROP_FONTSIZE,  8); ObjectSetInteger(0,n,OBJPROP_HIDDEN,    true);
    ObjectSetInteger(0,n,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_ZORDER,    Z_PNL_OBJ);   // [FIX 1]
}
void DelObj(string n){ if(ObjectFind(0,n)>=0) ObjectDelete(0,n); }

//══════════════════════════════════════════════════════════════════
//  MÁSCARA (tapador de velas futuras)
//  [FIX 3] Z_MASK=1, SIEMPRE por debajo del panel (Z_PNL_BG=90)
//══════════════════════════════════════════════════════════════════
void UpdateMask()
{
    if(ObjectFind(0,OBJ_ORIGIN)<0) return;
    datetime lineT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    if(lineT==0) return;

    double priceRef=ChartGetDouble(0,CHART_PRICE_MAX);
    int px=0, py=0;
    if(!ChartTimePriceToXY(0,0,lineT,priceRef,px,py)) { DelObj(OBJ_MASK); return; }

    int chartW=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
    int chartH=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
    if(chartW<=0||chartH<=0) return;

    if(px <= 3 || px >= chartW - 3) { DelObj(OBJ_MASK); return; }

    int maskW = chartW - px;
    if(maskW <= 0) { DelObj(OBJ_MASK); return; }

    color bgClr=(color)ChartGetInteger(0,CHART_COLOR_BACKGROUND);

    if(ObjectFind(0,OBJ_MASK)<0) ObjectCreate(0,OBJ_MASK,OBJ_RECTANGLE_LABEL,0,0,0);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_XDISTANCE,  px);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_YDISTANCE,  0);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_XSIZE,      maskW);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_YSIZE,      chartH);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_BGCOLOR,    bgClr);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_BORDER_TYPE,BORDER_FLAT);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_HIDDEN,     true);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_CORNER,     CORNER_LEFT_UPPER);
    ObjectSetInteger(0,OBJ_MASK,OBJPROP_ZORDER,     Z_MASK);   // [FIX 3]
}

void SetOriginLine(datetime t)
{
    g_savedOriginT = t;   // [FIX 5c] guardar siempre el datetime del origen
    if(ObjectFind(0,OBJ_ORIGIN)<0) ObjectCreate(0,OBJ_ORIGIN,OBJ_VLINE,0,t,0);
    ObjectMove(0,OBJ_ORIGIN,0,t,0);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_COLOR,      clrOrangeRed);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_WIDTH,      2);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_STYLE,      STYLE_SOLID);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_SELECTABLE, true);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_SELECTED,   false);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_BACK,       false);
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_HIDDEN,     false);
    ObjectSetString(0, OBJ_ORIGIN,OBJPROP_TEXT,       "◀ Origen");
    ObjectSetInteger(0,OBJ_ORIGIN,OBJPROP_ZORDER,     Z_TV_LINE);   // [FIX 1]
    UpdateMask();
}

//══════════════════════════════════════════════════════════════════
//  INTERFAZ TV — LÍNEAS Y ZONAS
//  [FIX 1] Z_TV_LINE=2, muy por debajo del panel (Z_PNL_OBJ=100)
//══════════════════════════════════════════════════════════════════
void CreateTVLine(string name, double price, color clr, int width=2)
{
    if(ObjectFind(0,name)<0)
    {
        ObjectCreate(0,name,OBJ_HLINE,0,0,price);
        ObjectSetInteger(0,name,OBJPROP_SELECTABLE, true);
        ObjectSetInteger(0,name,OBJPROP_HIDDEN,     false);
        ObjectSetInteger(0,name,OBJPROP_BACK,       false);
    }
    ObjectSetDouble(0, name,OBJPROP_PRICE, price);
    ObjectSetInteger(0,name,OBJPROP_COLOR, clr);
    ObjectSetInteger(0,name,OBJPROP_WIDTH, width);
    ObjectSetInteger(0,name,OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0,name,OBJPROP_ZORDER, Z_TV_LINE);   // [FIX 1] siempre aplicar
}

void CreateTVZone(string name,datetime t1,double p1,datetime t2,double p2,color clr)
{
    if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,p1,t2,p2);
    ObjectSetInteger(0,name,OBJPROP_TIME,  0,t1);
    ObjectSetDouble(0, name,OBJPROP_PRICE, 0,p1);
    ObjectSetInteger(0,name,OBJPROP_TIME,  1,t2);
    ObjectSetDouble(0, name,OBJPROP_PRICE, 1,p2);
    ObjectSetInteger(0,name,OBJPROP_COLOR,     clr);
    ObjectSetInteger(0,name,OBJPROP_FILL,      true);
    ObjectSetInteger(0,name,OBJPROP_BACK,      true);
    ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,name,OBJPROP_HIDDEN,    true);
    ObjectSetInteger(0,name,OBJPROP_ZORDER,    Z_TV_ZONE);   // [FIX 1]
}

void SetTVBox(string bgN, string t1N, string t2N,
              int lbX, int lbY, int lbW, int lbH,
              color bgClr, string txt1, color c1,
              string txt2="", color c2=clrWhite)
{
    if(ObjectFind(0,bgN)<0) ObjectCreate(0,bgN,OBJ_RECTANGLE_LABEL,0,0,0);
    ObjectSetInteger(0,bgN,OBJPROP_XDISTANCE,  lbX);
    ObjectSetInteger(0,bgN,OBJPROP_YDISTANCE,  lbY);
    ObjectSetInteger(0,bgN,OBJPROP_XSIZE,      lbW);
    ObjectSetInteger(0,bgN,OBJPROP_YSIZE,      lbH);
    ObjectSetInteger(0,bgN,OBJPROP_BGCOLOR,    bgClr);
    ObjectSetInteger(0,bgN,OBJPROP_BORDER_TYPE,BORDER_FLAT);
    ObjectSetInteger(0,bgN,OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0,bgN,OBJPROP_HIDDEN,     true);
    ObjectSetInteger(0,bgN,OBJPROP_CORNER,     CORNER_LEFT_UPPER);
    ObjectSetInteger(0,bgN,OBJPROP_ZORDER,     Z_TV_BOX);     // [FIX 1]

    if(ObjectFind(0,t1N)<0) ObjectCreate(0,t1N,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,t1N,OBJPROP_XDISTANCE,  lbX+5);
    ObjectSetInteger(0,t1N,OBJPROP_YDISTANCE,  lbY+4);
    ObjectSetString(0, t1N,OBJPROP_TEXT,       txt1);
    ObjectSetInteger(0,t1N,OBJPROP_FONTSIZE,   8);
    ObjectSetInteger(0,t1N,OBJPROP_COLOR,      c1);
    ObjectSetInteger(0,t1N,OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0,t1N,OBJPROP_HIDDEN,     true);
    ObjectSetInteger(0,t1N,OBJPROP_CORNER,     CORNER_LEFT_UPPER);
    ObjectSetInteger(0,t1N,OBJPROP_ZORDER,     Z_TV_BOXTXT);  // [FIX 1]

    if(t2N != "")
    {
        if(ObjectFind(0,t2N)<0) ObjectCreate(0,t2N,OBJ_LABEL,0,0,0);
        ObjectSetInteger(0,t2N,OBJPROP_XDISTANCE,  lbX+5);
        ObjectSetInteger(0,t2N,OBJPROP_YDISTANCE,  lbY+17);
        ObjectSetString(0, t2N,OBJPROP_TEXT,       txt2);
        ObjectSetInteger(0,t2N,OBJPROP_FONTSIZE,   8);
        ObjectSetInteger(0,t2N,OBJPROP_COLOR,      c2);
        ObjectSetInteger(0,t2N,OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0,t2N,OBJPROP_HIDDEN,     true);
        ObjectSetInteger(0,t2N,OBJPROP_CORNER,     CORNER_LEFT_UPPER);
        ObjectSetInteger(0,t2N,OBJPROP_ZORDER,     Z_TV_BOXTXT);  // [FIX 1]
    }
}

//══════════════════════════════════════════════════════════════════
//  NÚCLEO TV: actualiza zonas + etiquetas
//══════════════════════════════════════════════════════════════════
void UpdateTVInterface()
{
    if(!g_showTV) return;
    if(ObjectFind(0,OBJ_ORIGIN)<0) return;

    datetime originT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    if(originT==0) return;

    double entry=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
    double sl   =ObjectGetDouble(0,TV_SL,   OBJPROP_PRICE,0);
    double tp   =ObjectGetDouble(0,TV_TP,   OBJPROP_PRICE,0);
    if(entry<=0) return;

    int barSecs    = PeriodSeconds(PERIOD_CURRENT);
    datetime zoneS = originT - (datetime)(g_tvZoneW * barSecs);

    double tpHi = (tp>entry)?tp:entry;
    double tpLo = (tp>entry)?entry:tp;
    CreateTVZone(TV_ZONE_TP, zoneS, tpHi, originT, tpLo, TV_CLR_TP);

    double slHi = (sl<entry)?entry:sl;
    double slLo = (sl<entry)?sl:entry;
    CreateTVZone(TV_ZONE_SL, zoneS, slHi, originT, slLo, TV_CLR_SL);

    double pip     = GetPip();
    double lot     = GetLot();
    double riskPct = GetRiskPct();

    double pips_sl = (pip>0)?MathAbs(entry-sl)/pip:0;
    double pips_tp = (pip>0)?MathAbs(tp-entry)/pip:0;
    double pct_sl  = (entry>0)?MathAbs(entry-sl)/entry*100.0:0;
    double pct_tp  = (entry>0)?MathAbs(tp-entry)/entry*100.0:0;
    double risk    = CalcMoney(entry-sl,  lot);
    double reward  = CalcMoney(tp-entry,  lot);
    double rr      = (risk>0)?reward/risk:0;

    if(ObjectFind(0,PNL_PFX+"V_Risk")  >=0) { ObjectSetString(0,PNL_PFX+"V_Risk",  OBJPROP_TEXT,"-"+DoubleToString(risk,2)+"  $"); }
    if(ObjectFind(0,PNL_PFX+"V_Reward")>=0) { ObjectSetString(0,PNL_PFX+"V_Reward",OBJPROP_TEXT,"+"+DoubleToString(reward,2)+" $"); }
    if(ObjectFind(0,PNL_PFX+"V_RR")    >=0) { ObjectSetString(0,PNL_PFX+"V_RR",    OBJPROP_TEXT,(rr>0)?"1 : "+DoubleToString(rr,2):"---"); }

    double priceRef=ChartGetDouble(0,CHART_PRICE_MAX);
    int originPX=0, dummy=0;
    if(!ChartTimePriceToXY(0,0,originT,priceRef,originPX,dummy)) return;

    int chartW=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
    if(originPX <= 3 || originPX >= chartW-3) return;

    int yEntry=0,ySL=0,yTP=0,dummyX=0;
    ChartTimePriceToXY(0,0,originT,entry,dummyX,yEntry);
    ChartTimePriceToXY(0,0,originT,sl,   dummyX,ySL);
    ChartTimePriceToXY(0,0,originT,tp,   dummyX,yTP);

    int lbW = 218;
    int lbX = MathMax(4, originPX - lbW - 2);

    string tpTxt = StringFormat("TP  +%.0f pips (%.2f%%)   +$%.2f", pips_tp, pct_tp, reward);
    SetTVBox(TV_LBL_TP_BG, TV_LBL_TP_T1, "",
             lbX, yTP-13, lbW, 26,
             TV_CLR_TP_LBL, tpTxt, C'110,240,150');

    string enL1, enL2;
    int idx=g_trade.GetOpenIndex();
    if(idx>=0)
    {
        VirtualPosition pos; g_trade.GetPosition(idx,pos);
        double pnl=g_trade.CalcProfit(idx,entry);
        string pnlStr=(pnl>=0?"+":"")+DoubleToString(pnl,2)+" $";
        enL1=StringFormat("ENTRY %.*f  |  %s  |  Lot: %.2f", _Digits, entry, (pos.type==0?"BUY":"SELL"), pos.volume);
        enL2=StringFormat("P&L aprox: %s   |   R:B 1:%.2f", pnlStr, rr);
    }
    else
    {
        enL1=StringFormat("ENTRY %.*f  |  Lot: %.2f  (%.2f%%)", _Digits, entry, lot, riskPct);
        enL2=StringFormat("Riesgo: -$%.2f   Benef: +$%.2f   R:B 1:%.2f", risk, reward, rr);
    }
    color enL2Clr=(idx>=0)?C'230,210,80':C_TXTS;
    SetTVBox(TV_LBL_EN_BG, TV_LBL_EN_T1, TV_LBL_EN_T2,
             lbX, yEntry-21, lbW, 42,
             TV_CLR_EN_LBL, enL1, C_ACCENT, enL2, enL2Clr);

    string slTxt = StringFormat("SL  -%.0f pips (%.2f%%)   -$%.2f", pips_sl, pct_sl, risk);
    SetTVBox(TV_LBL_SL_BG, TV_LBL_SL_T1, "",
             lbX, ySL-13, lbW, 26,
             TV_CLR_SL_LBL, slTxt, C'240,110,110');

    // [NUEVO] Aplicar visibilidad de etiquetas según toggle
    long vis = g_tvLabelsVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS;
    ObjectSetInteger(0, TV_LBL_TP_BG, OBJPROP_TIMEFRAMES, vis);
    ObjectSetInteger(0, TV_LBL_TP_T1, OBJPROP_TIMEFRAMES, vis);
    ObjectSetInteger(0, TV_LBL_EN_BG, OBJPROP_TIMEFRAMES, vis);
    ObjectSetInteger(0, TV_LBL_EN_T1, OBJPROP_TIMEFRAMES, vis);
    ObjectSetInteger(0, TV_LBL_EN_T2, OBJPROP_TIMEFRAMES, vis);
    ObjectSetInteger(0, TV_LBL_SL_BG, OBJPROP_TIMEFRAMES, vis);
    ObjectSetInteger(0, TV_LBL_SL_T1, OBJPROP_TIMEFRAMES, vis);
}

void SyncPanelFromLines()
{
    if(!g_showTV) return;
    double entry=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
    double sl   =ObjectGetDouble(0,TV_SL,   OBJPROP_PRICE,0);
    double tp   =ObjectGetDouble(0,TV_TP,   OBJPROP_PRICE,0);
    double pip  =GetPip();
    if(entry<=0||pip<=0) return;

    if(ObjectFind(0,PNL_PFX+"Edit_SLp")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_SLp",OBJPROP_TEXT,IntegerToString((int)MathRound(MathAbs(entry-sl)/pip)));
    if(ObjectFind(0,PNL_PFX+"Edit_TPp")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_TPp",OBJPROP_TEXT,IntegerToString((int)MathRound(MathAbs(tp-entry)/pip)));

    double lot=GetLot();
    double riskPct=CalcRiskPctFromLot(lot,entry,sl);
    if(ObjectFind(0,PNL_PFX+"Edit_RskPct")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_RskPct",OBJPROP_TEXT,DoubleToString(riskPct,2));
}

void RecalcLinesFromPanel()
{
    if(!g_showTV) return;
    double entry=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
    if(entry<=0) return;
    double pip =GetPip();
    int slP=(int)StringToInteger(ObjectGetString(0,PNL_PFX+"Edit_SLp",OBJPROP_TEXT));
    int tpP=(int)StringToInteger(ObjectGetString(0,PNL_PFX+"Edit_TPp",OBJPROP_TEXT));
    ObjectSetDouble(0,TV_SL,OBJPROP_PRICE,entry-slP*pip);
    ObjectSetDouble(0,TV_TP,OBJPROP_PRICE,entry+tpP*pip);
    double riskPct=GetRiskPct();
    double lot=CalcLotFromRiskPct(riskPct,entry,entry-slP*pip);
    if(ObjectFind(0,PNL_PFX+"Edit_Lot")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_Lot",OBJPROP_TEXT,DoubleToString(lot,2));
    UpdateTVInterface();
}

void RecalcLotFromRiskPct()
{
    if(!g_showTV) return;
    double entry=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
    double sl   =ObjectGetDouble(0,TV_SL,   OBJPROP_PRICE,0);
    if(entry<=0||sl<=0) return;
    double riskPct=GetRiskPct();
    double lot=CalcLotFromRiskPct(riskPct,entry,sl);
    if(ObjectFind(0,PNL_PFX+"Edit_Lot")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_Lot",OBJPROP_TEXT,DoubleToString(lot,2));
    UpdateTVInterface();
}

void RecalcRiskPctFromLot()
{
    if(!g_showTV) return;
    double entry=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
    double sl   =ObjectGetDouble(0,TV_SL,   OBJPROP_PRICE,0);
    if(entry<=0||sl<=0) return;
    double lot=GetLot();
    double pct=CalcRiskPctFromLot(lot,entry,sl);
    if(ObjectFind(0,PNL_PFX+"Edit_RskPct")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_RskPct",OBJPROP_TEXT,DoubleToString(pct,2));
    UpdateTVInterface();
}

void InitTVInterface()
{
    double priceMax=ChartGetDouble(0,CHART_PRICE_MAX);
    double priceMin=ChartGetDouble(0,CHART_PRICE_MIN);
    double center  =(priceMax+priceMin)/2.0;
    double range   =(priceMax-priceMin)*0.12;
    double ts      =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    if(ts<=0) ts=SymbolInfoDouble(_Symbol,SYMBOL_POINT);

    double entryP=MathRound(center      /ts)*ts;
    double slP   =MathRound((center-range)/ts)*ts;
    double tpP   =MathRound((center+range)/ts)*ts;

    CreateTVLine(TV_ENTRY, entryP, C_ACCENT,         2);
    CreateTVLine(TV_SL,    slP,    C'220,60,60',      2);
    CreateTVLine(TV_TP,    tpP,    C'60,220,100',     2);

    double pip=GetPip();
    if(pip>0)
    {
        if(ObjectFind(0,PNL_PFX+"Edit_SLp")>=0)
            ObjectSetString(0,PNL_PFX+"Edit_SLp",OBJPROP_TEXT,IntegerToString((int)MathRound(MathAbs(entryP-slP)/pip)));
        if(ObjectFind(0,PNL_PFX+"Edit_TPp")>=0)
            ObjectSetString(0,PNL_PFX+"Edit_TPp",OBJPROP_TEXT,IntegerToString((int)MathRound(MathAbs(tpP-entryP)/pip)));
    }
    double riskPct=GetRiskPct();
    double lot=CalcLotFromRiskPct(riskPct,entryP,slP);
    if(ObjectFind(0,PNL_PFX+"Edit_Lot")>=0)
        ObjectSetString(0,PNL_PFX+"Edit_Lot",OBJPROP_TEXT,DoubleToString(lot,2));

    UpdateTVInterface();
}

void DeleteTVInterface()
{
    DelObj(TV_ENTRY); DelObj(TV_SL); DelObj(TV_TP);
    DelObj(TV_ZONE_TP); DelObj(TV_ZONE_SL);
    DelObj(TV_LBL_TP_BG); DelObj(TV_LBL_TP_T1);
    DelObj(TV_LBL_EN_BG); DelObj(TV_LBL_EN_T1); DelObj(TV_LBL_EN_T2);
    DelObj(TV_LBL_SL_BG); DelObj(TV_LBL_SL_T1);
}

//══════════════════════════════════════════════════════════════════
//  PANEL PRINCIPAL
//══════════════════════════════════════════════════════════════════
void DrawPanel()
{
    ObjectsDeleteAll(0, PNL_PFX);
    int x=g_panelX, y=g_panelY;
    const int W=PANEL_W;

    int H=42;
    if(!g_panelMin)
    {
        H+=6;
        H+=SH+2;
        if(g_showStats)   H+=RH*5+6;
        H+=SH+2;
        if(g_showOps)     H+=EH+4+EH+4+RH*3+4+30+4+BH+4;
        H+=SH+2;
        if(g_showTV)      H+=RH+8+BH+4;
        H+=SH+2;
        if(g_showTime)    H+=BH+4+RH+4;
        H+=SH+2;
        if(g_showRisk)    H+=BH+4;
        H+=SH+2;
        if(g_showPersist) H+=BH+4;
        H+=6;
    }

    _Rect(PNL_PFX+"BG",     x, y, W, H, C_BG, BORDER_SUNKEN, C_ACCENT);
    _Rect(PNL_PFX+"STRIPE", x, y, 3, H, C_ACCENT);
    _Rect(PNL_PFX+"HDR",    x, y, W, 40, C_HDR);

    _Lbl(PNL_PFX+"T1", x+10, y+5,  "SAMTRADER BACKTEST PRO", 9, C_TXT);
    _Lbl(PNL_PFX+"T2", x+10, y+21, "Javier Trader  ·  v4.2",  7, C_ACCENT);
    _Btn(PNL_PFX+"Btn_Minimize", x+W-60, y+8, 22, 18, g_panelMin?"□":"—", C_BTN);
    _Btn(PNL_PFX+"Btn_CloseEA",  x+W-34, y+8, 22, 18, "✕", C'130,25,25');

    if(g_panelMin){ ChartRedraw(); return; }
    int cy=y+48;

    // ── A. ESTADÍSTICAS ──────────────────────────────────────────
    _Btn(PNL_PFX+"Btn_Stats", x+2,cy,W-4,SH,(g_showStats?"▼  ":"▶  ")+"ESTADÍSTICAS",C_SEC,C_ACCENT);
    cy+=SH+2;
    if(g_showStats)
    {
        _Lbl(PNL_PFX+"L_Bal",  x+PAD,   cy+1,"Balance:",   8,C_TXTS);
        _Lbl(PNL_PFX+"V_Bal",  x+W-PAD, cy+1,"---",        8,C_TXT,true);    cy+=RH;
        _Lbl(PNL_PFX+"L_Wins", x+PAD,   cy+1,"Ganadas:",   8,C_TXTS);
        _Lbl(PNL_PFX+"V_Wins", x+W-PAD, cy+1,"0",          8,C_GREEN,true);  cy+=RH;
        _Lbl(PNL_PFX+"L_Loss", x+PAD,   cy+1,"Perdidas:",  8,C_TXTS);
        _Lbl(PNL_PFX+"V_Loss", x+W-PAD, cy+1,"0",          8,C_RED,true);    cy+=RH;
        _Lbl(PNL_PFX+"L_WR",   x+PAD,   cy+1,"Win Rate:",  8,C_TXTS);
        _Lbl(PNL_PFX+"V_WR",   x+W-PAD, cy+1,"0.0%",       8,clrYellow,true);cy+=RH;
        _Lbl(PNL_PFX+"L_Last", x+PAD,   cy+1,"Último:",    8,C_TXTS);
        _Lbl(PNL_PFX+"V_Last", x+W-PAD, cy+1,"---",        8,C_TXT,true);    cy+=RH+4;
    }

    // ── B. OPERACIONES ───────────────────────────────────────────
    _Btn(PNL_PFX+"Btn_Ops", x+2,cy,W-4,SH,(g_showOps?"▼  ":"▶  ")+"OPERACIONES",C_SEC,C_ACCENT);
    cy+=SH+2;
    if(g_showOps)
    {
        int fw2 = (W-PAD*2-6)/2;
        _Lbl(PNL_PFX+"L_Lot",    x+PAD,           cy+3,"Lot:",   8,C_TXTS);
        _Edit(PNL_PFX+"Edit_Lot",x+PAD+28,        cy, fw2-28, EH,"0.10",C_BTN2,clrWhite);
        _Lbl(PNL_PFX+"L_Rsk",    x+PAD+fw2+4,     cy+3,"Rsk%:",  8,clrYellow);
        _Edit(PNL_PFX+"Edit_RskPct",x+PAD+fw2+36, cy, fw2-32, EH,DoubleToString(InpDefaultRiskPct,1),C_BTN2,clrYellow);
        cy+=EH+4;

        int fw3=(W-PAD*2-6)/2;
        _Lbl(PNL_PFX+"L_SLp",   x+PAD,        cy+3,"SL pips:",8,C_RED);
        _Edit(PNL_PFX+"Edit_SLp",x+PAD+46,    cy, fw3-46, EH,IntegerToString(InpSLPipsDefault),C_BTN2,C_RED);
        _Lbl(PNL_PFX+"L_TPp",   x+PAD+fw3+4,  cy+3,"TP pips:",8,C_GREEN);
        _Edit(PNL_PFX+"Edit_TPp",x+PAD+fw3+50, cy, fw3-46, EH,IntegerToString(InpTPPipsDefault),C_BTN2,C_GREEN);
        cy+=EH+4;

        _Lbl(PNL_PFX+"L_Risk",   x+PAD,   cy+1,"Riesgo:",   8,C_TXTS);
        _Lbl(PNL_PFX+"V_Risk",   x+W-PAD, cy+1,"--- $",     8,C_RED,true);     cy+=RH;
        _Lbl(PNL_PFX+"L_Reward", x+PAD,   cy+1,"Beneficio:",8,C_TXTS);
        _Lbl(PNL_PFX+"V_Reward", x+W-PAD, cy+1,"--- $",     8,C_GREEN,true);   cy+=RH;
        _Lbl(PNL_PFX+"L_RR",     x+PAD,   cy+1,"Ratio R:B:",8,C_TXTS);
        _Lbl(PNL_PFX+"V_RR",     x+W-PAD, cy+1,"---",       8,clrYellow,true); cy+=RH+4;

        int hw=(W-PAD*2-4)/2;
        _Btn(PNL_PFX+"Btn_Buy",     x+PAD,      cy,hw,30,"▲  BUY",     C'0,130,70', clrWhite,9);
        _Btn(PNL_PFX+"Btn_Sell",    x+PAD+hw+4, cy,hw,30,"▼  SELL",    C'160,35,35',clrWhite,9);
        cy+=30+4;
        _Btn(PNL_PFX+"Btn_CloseAll",x+PAD,      cy,W-PAD*2,BH,"✖  CERRAR POSICIÓN",C'140,110,0',clrBlack);
        cy+=BH+4;
    }

    // ── C. PANEL TV ──────────────────────────────────────────────
    color tvC = g_showTV ? C'0,80,110' : C_SEC;
    _Btn(PNL_PFX+"Btn_TV", x+2,cy,W-4,SH,(g_showTV?"◆  ":"◇  ")+"PANEL DE ORDEN  (TV-Style)",tvC,C_ACCENT);
    cy+=SH+2;
    if(g_showTV)
    {
        int sw=28;
        _Lbl(PNL_PFX+"L_ZW",   x+PAD,       cy+3,"Ancho zona:",8,C_TXTS);
        _Btn(PNL_PFX+"Btn_ZWm",x+PAD+78,    cy,sw,RH,"–",C_BTN);
        _Lbl(PNL_PFX+"L_ZWv",  x+PAD+110,   cy+3,IntegerToString(g_tvZoneW)+" velas",8,C_TXT);
        _Btn(PNL_PFX+"Btn_ZWp",x+PAD+160,   cy,sw,RH,"+",C_BTN);
        cy+=RH+6;
        // [NUEVO] Botón ocultar/mostrar etiquetas TV
        color lbBtnClr = g_tvLabelsVisible ? C'20,70,40' : C'70,20,20';
        string lbBtnTxt = g_tvLabelsVisible ? "◉  OCULTAR ETIQUETAS" : "○  MOSTRAR ETIQUETAS";
        _Btn(PNL_PFX+"Btn_TVLbl", x+PAD, cy, W-PAD*2, BH, lbBtnTxt, lbBtnClr, clrWhite);
        cy+=BH+4;
    }

    // ── D. CONTROL DE TIEMPO ─────────────────────────────────────
    _Btn(PNL_PFX+"Btn_TimeCtrl",x+2,cy,W-4,SH,(g_showTime?"▼  ":"▶  ")+"CONTROL DE TIEMPO",C_SEC,C_ACCENT);
    cy+=SH+2;
    if(g_showTime)
    {
        int bw=(W-PAD*2-8)/3;
        _Btn(PNL_PFX+"Btn_Play",    x+PAD,        cy,bw,BH,"▶  PLAY",   C'0,110,55');
        _Btn(PNL_PFX+"Btn_Pause",   x+PAD+bw+4,   cy,bw,BH,"⏸  PAUSA", C'140,70,0');
        _Btn(PNL_PFX+"Btn_NextBar", x+PAD+bw*2+8, cy,bw,BH,">  VELA",  C'25,60,150');
        cy+=BH+4;
        int sw2=28;
        _Btn(PNL_PFX+"Btn_Sm", x+PAD,         cy,sw2,RH,"S–",C_BTN);
        _Lbl(PNL_PFX+"L_Spd",  x+PAD+sw2+4,  cy+1,"Vel: "+IntegerToString(g_speedLevel),8,C_TXT);
        _Btn(PNL_PFX+"Btn_Sp", x+PAD+sw2+62, cy,sw2,RH,"S+",C_BTN);
        cy+=RH+4;
    }

    // ── E. GESTIÓN DE RIESGO ─────────────────────────────────────
    _Btn(PNL_PFX+"Btn_RiskSec",x+2,cy,W-4,SH,(g_showRisk?"▼  ":"▶  ")+"GESTIÓN DE RIESGO",C_SEC,C_ACCENT);
    cy+=SH+2;
    if(g_showRisk)
    {
        int hw2=(W-PAD*2-4)/2;
        _Btn(PNL_PFX+"Btn_BE",  x+PAD,       cy,hw2,BH,"⚡  BREAKEVEN",  C'15,50,110');
        _Btn(PNL_PFX+"Btn_50",  x+PAD+hw2+4, cy,hw2,BH,"✂  CIERRE 50%", C'60,30,100');
        cy+=BH+4;
    }

    // ── F. PERSISTENCIA ──────────────────────────────────────────
    _Btn(PNL_PFX+"Btn_PersistSec",x+2,cy,W-4,SH,(g_showPersist?"▼  ":"▶  ")+"PERSISTENCIA",C_SEC,C_ACCENT);
    cy+=SH+2;
    if(g_showPersist)
    {
        int bw3=(W-PAD*2-8)/3;
        _Btn(PNL_PFX+"Btn_Save",  x+PAD,         cy,bw3,BH,"💾 GUARDAR",   C'20,50,20');
        _Btn(PNL_PFX+"Btn_Load",  x+PAD+bw3+4,   cy,bw3,BH,"📂 CARGAR",    C'18,30,70');
        _Btn(PNL_PFX+"Btn_Reset", x+PAD+bw3*2+8, cy,bw3,BH,"↺ REINICIAR", C'70,15,15');
    }

    UpdatePanelStats();
    ChartRedraw();
}

void UpdatePanelStats()
{
    if(g_panelMin||!g_showStats) return;
    if(ObjectFind(0,PNL_PFX+"V_Bal")<0) return;
    double bal=g_trade.GetBalance();
    ObjectSetString(0, PNL_PFX+"V_Bal",  OBJPROP_TEXT, DoubleToString(bal,2)+" $");
    ObjectSetInteger(0,PNL_PFX+"V_Bal",  OBJPROP_COLOR,(bal>=g_trade.GetInitBal())?C_GREEN:C_RED);
    ObjectSetString(0, PNL_PFX+"V_Wins", OBJPROP_TEXT, IntegerToString(g_trade.GetWins()));
    ObjectSetString(0, PNL_PFX+"V_Loss", OBJPROP_TEXT, IntegerToString(g_trade.GetLosses()));
    double wr=g_trade.GetWinRate();
    ObjectSetString(0, PNL_PFX+"V_WR",   OBJPROP_TEXT, DoubleToString(wr,1)+"%");
    ObjectSetInteger(0,PNL_PFX+"V_WR",   OBJPROP_COLOR,(wr>=50)?C_GREEN:C_RED);
    string last=g_trade.GetLastResult();
    ObjectSetString(0, PNL_PFX+"V_Last", OBJPROP_TEXT, last);
    ObjectSetInteger(0,PNL_PFX+"V_Last", OBJPROP_COLOR,
                     (StringFind(last,"✔")>=0)?C_GREEN:(StringFind(last,"✘")>=0)?C_RED:C_TXTS);
    if(ObjectFind(0,PNL_PFX+"L_Spd")>=0)
        ObjectSetString(0,PNL_PFX+"L_Spd",OBJPROP_TEXT,"Vel: "+IntegerToString(g_speedLevel));
    if(g_showTV&&ObjectFind(0,PNL_PFX+"L_ZWv")>=0)
        ObjectSetString(0,PNL_PFX+"L_ZWv",OBJPROP_TEXT,IntegerToString(g_tvZoneW)+" velas");
}

//══════════════════════════════════════════════════════════════════
//  ETIQUETA P&L FLOTANTE
//══════════════════════════════════════════════════════════════════
void UpdatePnLLabel()
{
    int idx=g_trade.GetOpenIndex();
    if(idx<0){ DelObj(OBJ_PNL_LBL); return; }
    VirtualPosition pos; if(!g_trade.GetPosition(idx,pos)) return;
    datetime originT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    int shift=iBarShift(_Symbol,PERIOD_CURRENT,originT,false);
    double curP=(shift>=0)?iClose(_Symbol,PERIOD_CURRENT,shift):pos.openPrice;
    double pnl=g_trade.CalcProfit(idx,curP);
    string txt=(pnl>=0?"▲  +":"▼  ")+DoubleToString(pnl,2)+" $";
    if(ObjectFind(0,OBJ_PNL_LBL)<0) ObjectCreate(0,OBJ_PNL_LBL,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_CORNER,    CORNER_LEFT_LOWER);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_XDISTANCE, g_panelX+PANEL_W+12);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_YDISTANCE, 30);
    ObjectSetString(0, OBJ_PNL_LBL,OBJPROP_TEXT,      txt);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_COLOR,     (pnl>=0)?C_GREEN:C_RED);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_FONTSIZE,  13);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_HIDDEN,    false);
    ObjectSetInteger(0,OBJ_PNL_LBL,OBJPROP_ZORDER,    Z_PNL_OBJ);
}

//══════════════════════════════════════════════════════════════════
//  SIMULACIÓN — AVANCE DE VELAS
//══════════════════════════════════════════════════════════════════
void EnsureOriginVisible()
{
    if(ObjectFind(0,OBJ_ORIGIN)<0) return;
    datetime originT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    int originShift=iBarShift(_Symbol,PERIOD_CURRENT,originT,false);
    if(originShift<0) return;

    int firstBar   =(int)ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR);
    int visibleBars=(int)ChartGetInteger(0,CHART_VISIBLE_BARS);
    if(visibleBars<=0) return;

    int rightEdgeShift=MathMax(0, firstBar-visibleBars+1);

    if(originShift - rightEdgeShift < 8)
    {
        int newOffset=MathMax(0, originShift - (int)(visibleBars*0.3));
        ChartNavigate(0,CHART_END,newOffset);
        g_needMaskRefresh=true;
    }
}

void RevealNextBar()
{
    datetime currentT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    if(currentT==0) return;

    int curShift=iBarShift(_Symbol,PERIOD_CURRENT,currentT,false);
    if(curShift<=0){ g_simPaused=true; return; }

    int nextShift=curShift-1;
    datetime newT=iTime(_Symbol,PERIOD_CURRENT,nextShift);
    if(newT<=0||newT<=currentT){ g_simPaused=true; return; }

    MqlRates nextBar[];
    if(CopyRates(_Symbol,PERIOD_CURRENT,nextShift,1,nextBar)<1) return;

    int idx=g_trade.GetOpenIndex();
    if(idx>=0)
    {
        VirtualPosition pos; g_trade.GetPosition(idx,pos);
        double hi=nextBar[0].high, lo=nextBar[0].low;
        bool closed=false;
        if(pos.type==0)
        {
            if(pos.sl>0&&lo<=pos.sl){ g_trade.Close(idx,pos.sl,newT,"SL ✘"); closed=true; }
            else if(pos.tp>0&&hi>=pos.tp){ g_trade.Close(idx,pos.tp,newT,"TP ✔"); closed=true; }
        }
        else
        {
            if(pos.sl>0&&hi>=pos.sl){ g_trade.Close(idx,pos.sl,newT,"SL ✘"); closed=true; }
            else if(pos.tp>0&&lo<=pos.tp){ g_trade.Close(idx,pos.tp,newT,"TP ✔"); closed=true; }
        }
        if(closed)
        {
            g_currentPos=-1;
            DelObj(OBJ_PNL_LBL);
            DrawPanel();
        }
    }

    SetOriginLine(newT);
    EnsureOriginVisible();

    if(g_showTV) UpdateTVInterface();
    UpdatePanelStats();
    UpdatePnLLabel();
}

//══════════════════════════════════════════════════════════════════
//  EJECUTAR ORDEN VIRTUAL
//══════════════════════════════════════════════════════════════════
void ExecuteVirtualOrder(int type)
{
    if(!g_showTV){ Alert("Activa primero el Panel TV (botón ◇ PANEL DE ORDEN)"); return; }
    double entry=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
    double sl   =ObjectGetDouble(0,TV_SL,   OBJPROP_PRICE,0);
    double tp   =ObjectGetDouble(0,TV_TP,   OBJPROP_PRICE,0);
    double lot  =GetLot();
    if(lot<=0)   lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    if(entry<=0) return;
    datetime openT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    g_currentPos=g_trade.Open(type,lot,sl,tp,entry,openT);
    UpdateTVInterface();
    UpdatePanelStats();
    UpdatePnLLabel();
}

//══════════════════════════════════════════════════════════════════
//  PERSISTENCIA
//══════════════════════════════════════════════════════════════════
void SaveSession()
{
    int h=FileOpen(SAVE_FILE,FILE_BIN|FILE_WRITE);
    if(h==INVALID_HANDLE){ Alert("Error al guardar"); return; }
    datetime originT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    FileWriteLong(h,(long)originT);
    int cnt=0;
    for(int i=0;i<MAX_POS;i++) cnt++;
    FileWriteDouble(h,g_trade.GetBalance());
    FileClose(h);
    Alert("Sesión guardada (balance: "+DoubleToString(g_trade.GetBalance(),2)+" $)");
}
void LoadSession()
{
    if(!FileIsExist(SAVE_FILE)){ Alert("No existe sesión guardada"); return; }
    Alert("Cargando sesión...");
}
void ResetAll()
{
    g_trade.Reset(); g_currentPos=-1; g_simPaused=true;
    DelObj(OBJ_PNL_LBL);
    DrawPanel();
    Alert("Reiniciado. Balance: "+DoubleToString(InpInitialBalance,2)+" $");
}

//══════════════════════════════════════════════════════════════════
//  MANEJADOR DE CLICS
//══════════════════════════════════════════════════════════════════
void HandleClick(string sp)
{
    if(sp==PNL_PFX+"Btn_Minimize"){ g_panelMin=!g_panelMin; DrawPanel(); return; }
    if(sp==PNL_PFX+"Btn_CloseEA") { ExpertRemove(); return; }

    if(sp==PNL_PFX+"Btn_Stats")     { g_showStats=!g_showStats;      DrawPanel(); return; }
    if(sp==PNL_PFX+"Btn_Ops")       { g_showOps=!g_showOps;          DrawPanel(); return; }
    if(sp==PNL_PFX+"Btn_TimeCtrl")  { g_showTime=!g_showTime;        DrawPanel(); return; }
    if(sp==PNL_PFX+"Btn_RiskSec")   { g_showRisk=!g_showRisk;        DrawPanel(); return; }
    if(sp==PNL_PFX+"Btn_PersistSec"){ g_showPersist=!g_showPersist;  DrawPanel(); return; }

    if(sp==PNL_PFX+"Btn_TV")
    {
        g_showTV=!g_showTV;
        if(g_showTV) InitTVInterface();
        else         DeleteTVInterface();
        DrawPanel(); return;
    }
    if(sp==PNL_PFX+"Btn_TVLbl")
    {
        g_tvLabelsVisible=!g_tvLabelsVisible;
        if(g_showTV) UpdateTVInterface();
        DrawPanel(); return;
    }
    if(sp==PNL_PFX+"Btn_ZWm")
    {
        g_tvZoneW=MathMax(3,g_tvZoneW-3);
        if(g_showTV) UpdateTVInterface();
        if(ObjectFind(0,PNL_PFX+"L_ZWv")>=0) ObjectSetString(0,PNL_PFX+"L_ZWv",OBJPROP_TEXT,IntegerToString(g_tvZoneW)+" velas");
        return;
    }
    if(sp==PNL_PFX+"Btn_ZWp")
    {
        g_tvZoneW=MathMin(200,g_tvZoneW+3);
        if(g_showTV) UpdateTVInterface();
        if(ObjectFind(0,PNL_PFX+"L_ZWv")>=0) ObjectSetString(0,PNL_PFX+"L_ZWv",OBJPROP_TEXT,IntegerToString(g_tvZoneW)+" velas");
        return;
    }
    if(sp==PNL_PFX+"Btn_Buy")  { ExecuteVirtualOrder(0); return; }
    if(sp==PNL_PFX+"Btn_Sell") { ExecuteVirtualOrder(1); return; }
    if(sp==PNL_PFX+"Btn_CloseAll")
    {
        int idx=g_trade.GetOpenIndex();
        if(idx>=0)
        {
            datetime t=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
            double curP=ObjectGetDouble(0,TV_ENTRY,OBJPROP_PRICE,0);
            if(curP<=0) curP=SymbolInfoDouble(_Symbol,SYMBOL_BID);
            g_trade.CloseAll(curP,t);
            g_currentPos=-1; DelObj(OBJ_PNL_LBL);
        }
        UpdatePanelStats(); if(g_showTV) UpdateTVInterface(); return;
    }
    if(sp==PNL_PFX+"Btn_Play")    { g_simPaused=false; g_timerTick=0; return; }
    if(sp==PNL_PFX+"Btn_Pause")   { g_simPaused=true; return; }
    if(sp==PNL_PFX+"Btn_NextBar") { RevealNextBar(); ChartRedraw(); return; }
    if(sp==PNL_PFX+"Btn_Sm")
    {
        g_speedLevel=MathMax(1,g_speedLevel-1);
        if(ObjectFind(0,PNL_PFX+"L_Spd")>=0) ObjectSetString(0,PNL_PFX+"L_Spd",OBJPROP_TEXT,"Vel: "+IntegerToString(g_speedLevel));
        return;
    }
    if(sp==PNL_PFX+"Btn_Sp")
    {
        g_speedLevel=MathMin(10,g_speedLevel+1);
        if(ObjectFind(0,PNL_PFX+"L_Spd")>=0) ObjectSetString(0,PNL_PFX+"L_Spd",OBJPROP_TEXT,"Vel: "+IntegerToString(g_speedLevel));
        return;
    }
    if(sp==PNL_PFX+"Btn_BE")
    {
        int idx=g_trade.GetOpenIndex();
        if(idx>=0)
        {
            VirtualPosition pos; g_trade.GetPosition(idx,pos);
            g_trade.ModifySLTP(idx,pos.openPrice,0);
            if(g_showTV) ObjectSetDouble(0,TV_SL,OBJPROP_PRICE,pos.openPrice);
            if(g_showTV) UpdateTVInterface();
        }
        return;
    }
    if(sp==PNL_PFX+"Btn_50")
    {
        int idx=g_trade.GetOpenIndex();
        if(idx>=0)
        {
            VirtualPosition pos; g_trade.GetPosition(idx,pos);
            datetime t=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
            bool closed=g_trade.PartialClose(idx,pos.openPrice,t);
            if(closed){ g_currentPos=-1; DelObj(OBJ_PNL_LBL); }
            UpdatePanelStats();
        }
        return;
    }
    if(sp==PNL_PFX+"Btn_Save")  { SaveSession(); return; }
    if(sp==PNL_PFX+"Btn_Load")  { LoadSession(); return; }
    if(sp==PNL_PFX+"Btn_Reset") { ResetAll(); return; }
}

//══════════════════════════════════════════════════════════════════
//  [FIX 5] Navegar el gráfico para mostrar el origen
//  Usa el datetime guardado en g_savedOriginT + iBarShift, que
//  cuenta las barras reales del mercado (sin gaps de fines de semana
//  ni festivos, que aritmética de tiempo pura sobreestimaba y
//  dejaba el gráfico posicionado demasiado lejos en el pasado).
//══════════════════════════════════════════════════════════════════
void NavigateToOrigin()
{
    datetime originT = (g_savedOriginT > 0) ? g_savedOriginT
                       : (datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
    if(originT == 0) return;

    // iBarShift devuelve el índice real del bar (0 = bar actual).
    // Para FOREX los gaps de fin de semana/festivos hacen que la
    // aritmética de tiempo sobreestime el índice y el gráfico quede
    // posicionado demasiado lejos en el pasado.
    int originShift = iBarShift(_Symbol, PERIOD_CURRENT, originT, false);

    // Si iBarShift no pudo resolverlo todavía (barras no cargadas),
    // se usa estimación por tiempo como fallback y se reintenta.
    if(originShift < 0)
    {
        int periodSec = PeriodSeconds(PERIOD_CURRENT);
        if(periodSec <= 0) return;
        datetime nowT = TimeCurrent();
        originShift = (nowT > originT) ? (int)((nowT - originT) / periodSec) : 50;
        g_navigateRetries = MathMax(g_navigateRetries, 3); // asegurar más intentos
    }

    int visibleBars = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
    if(visibleBars <= 0) visibleBars = 100;

    // Origen al 70% desde la izquierda = 30% desde la derecha
    int offset = originShift - (int)(visibleBars * 0.30);
    if(offset < 0) offset = 0;

    ChartSetInteger(0, CHART_AUTOSCROLL, false);
    ChartNavigate(0, CHART_END, offset);
}

//══════════════════════════════════════════════════════════════════
//  OnInit
//══════════════════════════════════════════════════════════════════
int OnInit()
{
    // ── Detectar si es reinicio por cambio de temporalidad ────────
    // MT5 llama OnDeinit+OnInit cuando el usuario cambia timeframe.
    // UninitializeReason() devuelve el motivo del OnDeinit anterior.
    // REASON_CHARTCHANGE = el usuario cambió symbol/timeframe.
    // Las variables globales de MQL5 se PRESERVAN entre OnDeinit y OnInit,
    // por eso g_savedOriginT y g_simPaused siguen válidas aquí.
    bool isChartChange = (UninitializeReason() == REASON_CHARTCHANGE);

    g_licencia_ok = VerificarLicenciaWeb();
    if(!g_licencia_ok){ Alert("QuantCore: Licencia inválida para backtest_simulator. Verifica tu token."); return INIT_FAILED; }
    g_last_heartbeat = TimeCurrent();

    // Solo reiniciar el gestor de trades en carga FRESCA, nunca en cambio de temporalidad
    // (si se reiniciara, el trader perdería su balance y posiciones virtuales)
    if(!isChartChange)
        g_trade.Init(InpInitialBalance);

    // Advertencia + pausa automática si estaba en play al cambiar temporalidad
    if(isChartChange && !g_simPaused)
    {
        g_simPaused=true;
        MessageBox("⚠  BACKTEST EN MARCHA\n\n"
                   "Cambiaste de temporalidad mientras el backtest estaba activo.\n"
                   "El backtest ha sido PAUSADO automáticamente.\n\n"
                   "Para cambiar de temporalidad mantén el backtest en PAUSA.",
                   "SAMTRADER – Advertencia", MB_OK|MB_ICONWARNING);
    }

    ObjectsDeleteAll(0,PNL_PFX);
    DeleteTVInterface();
    DelObj(OBJ_ORIGIN); DelObj(OBJ_MASK); DelObj(OBJ_PNL_LBL);

    ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,true);
    ChartSetInteger(0,CHART_AUTOSCROLL,false);

    g_lastPeriod=ChartPeriod(0);

    datetime startT;
    if(isChartChange && g_savedOriginT > 0)
    {
        // ── Reinicio por cambio de temporalidad ──────────────────
        // Restaurar el origen desde el datetime guardado en OnDeinit.
        // La línea se coloca en exactamente el mismo instante que estaba,
        // independientemente de la nueva temporalidad.
        startT = g_savedOriginT;
    }
    else
    {
        // ── Primera carga: colocar origen en la vista actual ─────
        int firstBar   =(int)ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR);
        int visibleBars=(int)ChartGetInteger(0,CHART_VISIBLE_BARS);
        int totalBars  =iBars(_Symbol,PERIOD_CURRENT);
        int targetShift=firstBar-(int)(visibleBars*0.80);
        if(targetShift<1)          targetShift=1;
        if(targetShift>=totalBars) targetShift=totalBars-1;
        startT=iTime(_Symbol,PERIOD_CURRENT,targetShift);
        if(startT<=0) startT=iTime(_Symbol,PERIOD_CURRENT,1);
    }

    SetOriginLine(startT);
    DrawPanel();

    // Navegar al origen inmediatamente + activar reintentos para sobrevivir
    // la animación residual de MT5 tras el cambio de temporalidad
    if(isChartChange)
    {
        NavigateToOrigin();
        g_navigateRetries=10;
    }

    EventSetMillisecondTimer(150);
    ChartRedraw();
    return INIT_SUCCEEDED;
}

//══════════════════════════════════════════════════════════════════
//  OnDeinit
//══════════════════════════════════════════════════════════════════
void OnDeinit(const int reason)
{
    // [FIX 5c] Antes de destruir objetos, guardar el datetime del origen.
    // g_savedOriginT es una variable global que MT5 PRESERVA entre OnDeinit y OnInit
    // cuando el reinicio es por cambio de temporalidad (REASON_CHARTCHANGE).
    // Así OnInit puede restaurar exactamente donde estaba la línea roja.
    if(ObjectFind(0,OBJ_ORIGIN)>=0)
        g_savedOriginT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);

    EventKillTimer();
    ObjectsDeleteAll(0,PNL_PFX);
    DeleteTVInterface();
    DelObj(OBJ_ORIGIN); DelObj(OBJ_MASK); DelObj(OBJ_PNL_LBL);
    ChartRedraw();
}

//══════════════════════════════════════════════════════════════════
//  OnTimer (cada 150ms)
//══════════════════════════════════════════════════════════════════
int GetSpeedTicks() { return MathMax(1,11-g_speedLevel); }

void OnTimer()
{
    g_timerTick++;

    // [FIX 5b] MT5 resetea CHART_AUTOSCROLL=true al cambiar temporalidad y cada tick
    // del broker arrastra el gráfico al bar actual. Lo forzamos false en CADA tick
    // del timer para que nunca prevalezca el autoscroll de MT5 mientras el EA esté activo.
    ChartSetInteger(0,CHART_AUTOSCROLL,false);

    if(g_licencia_ok){ datetime _nt=TimeCurrent(); if(_nt-g_last_heartbeat>=HeartbeatInterval){ g_last_heartbeat=_nt; if(!SendHeartbeat()){ g_licencia_ok=false; ExpertRemove(); return; } } }

    // [FIX 4] Actualización diferida de máscara — el gráfico ya se estabilizó
    if(g_needMaskRefresh)
    {
        g_needMaskRefresh=false;
        UpdateMask();
        if(g_showTV) UpdateTVInterface();
        ChartRedraw();
    }

    // [FIX 5b] Reintentos de navegación al cambiar temporalidad.
    // 10 ticks × 150ms = 1500ms de corrección continua para sobrevivir
    // la animación de MT5 y los ticks del broker que pisan el ChartNavigate.
    if(g_navigateRetries > 0)
    {
        g_navigateRetries--;
        NavigateToOrigin();
        g_needMaskRefresh=true;
    }

    if(!g_simPaused&&g_timerTick%GetSpeedTicks()==0)
        RevealNextBar();

    if(g_timerTick%6==0)
    {
        if(g_showTV) UpdateTVInterface();
        UpdatePnLLabel();
        UpdatePanelStats();
    }
}

//══════════════════════════════════════════════════════════════════
//  OnChartEvent
//══════════════════════════════════════════════════════════════════
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
    // ── [FIX 2] Arrastre del panel ────────────────────────────────
    // Solo se activa si el usuario NO está arrastrando la línea de origen
    if(id==CHARTEVENT_MOUSE_MOVE)
    {
        int mx=(int)lp, my=(int)dp;
        bool lBtn=((StringToInteger(sp)&1)!=0);

        if(!lBtn)
        {
            // Botón suelto → limpiar todos los flags de arrastre
            g_dragMode=0;
            g_originDragging=false;
        }
        else
        {
            // [FIX 2] Iniciar arrastre de panel SOLO si NO hay drag de origen activo.
            // Se usa únicamente g_originDragging (se activa en CHARTEVENT_OBJECT_DRAG
            // y se limpia al soltar el botón). NO se usa OBJPROP_SELECTED porque ese
            // flag queda true tras cualquier clic en la línea y bloquearía el panel.
            if(g_dragMode==0 && !g_originDragging &&
               mx>=g_panelX && mx<=g_panelX+PANEL_W &&
               my>=g_panelY && my<=g_panelY+40)
            {
                g_dragMode=1;
                g_dragOffX=mx-g_panelX;
                g_dragOffY=my-g_panelY;
            }
            else if(g_dragMode==1)
            {
                int nx=MathMax(0,mx-g_dragOffX), ny=MathMax(0,my-g_dragOffY);
                if(nx!=g_panelX||ny!=g_panelY){ g_panelX=nx; g_panelY=ny; DrawPanel(); }
            }
        }
    }

    // ── [FIX 2] Arrastre de la línea de origen ───────────────────
    if(id==CHARTEVENT_OBJECT_DRAG&&sp==OBJ_ORIGIN)
    {
        g_originDragging=true;  // [FIX 2] marcar que el origen se está moviendo
        g_dragMode=0;           // [FIX 2] cancelar cualquier arrastre de panel activo
        // [FIX 5c] Guardar el nuevo datetime del origen tras arrastrarlo
        g_savedOriginT=(datetime)ObjectGetInteger(0,OBJ_ORIGIN,OBJPROP_TIME,0);
        UpdateMask();
        if(g_showTV) UpdateTVInterface();
    }

    // ── Arrastre de líneas TV (Entry / SL / TP) ──────────────────
    if(id==CHARTEVENT_OBJECT_DRAG&&(sp==TV_ENTRY||sp==TV_SL||sp==TV_TP))
    {
        SyncPanelFromLines();
        UpdateTVInterface();
        if(g_currentPos>=0&&(sp==TV_SL||sp==TV_TP))
        {
            double newSL=ObjectGetDouble(0,TV_SL,OBJPROP_PRICE,0);
            double newTP=ObjectGetDouble(0,TV_TP,OBJPROP_PRICE,0);
            g_trade.ModifySLTP(g_currentPos,newSL,newTP);
        }
    }

    // ── [FIX 4 / FIX 5] Cambio de zoom, scroll o temporalidad ────
    if(id==CHARTEVENT_CHART_CHANGE)
    {
        // [FIX 5] Detectar cambio de temporalidad
        ENUM_TIMEFRAMES curPeriod=ChartPeriod(0);
        if(curPeriod!=g_lastPeriod)
        {
            g_lastPeriod=curPeriod;

            // Bloqueo: no se permite cambiar temporalidad con el backtest en marcha
            if(!g_simPaused)
            {
                g_simPaused=true;
                DrawPanel(); // actualizar botones Play/Pause visualmente
                // MessageBox garantiza que el trader vea la advertencia (Alert() no siempre
                // se muestra cuando el evento viene de un cambio de timeframe en MT5)
                MessageBox("⚠  BACKTEST EN MARCHA\n\n"
                           "Cambiaste de temporalidad mientras el backtest estaba activo.\n"
                           "El backtest ha sido PAUSADO automáticamente.\n\n"
                           "Para cambiar de temporalidad siempre mantén el backtest en PAUSA.",
                           "SAMTRADER – Advertencia", MB_OK|MB_ICONWARNING);
            }

            // Activar reintentos: MT5 resetea AUTOSCROLL y su animación pisa ChartNavigate.
            // 10 ticks × 150ms = 1500ms de corrección continua.
            g_navigateRetries=10;
        }

        // [FIX 4] Diferir la actualización — ChartTimePriceToXY puede dar
        // resultados inestables mientras el gráfico aún está animándose.
        // El timer lo procesará en el siguiente tick (≈150ms después).
        g_needMaskRefresh=true;
    }

    // ── Edición de campos del panel ──────────────────────────────
    if(id==CHARTEVENT_OBJECT_ENDEDIT)
    {
        if(sp==PNL_PFX+"Edit_Lot")    RecalcRiskPctFromLot();
        if(sp==PNL_PFX+"Edit_RskPct") RecalcLotFromRiskPct();
        if(sp==PNL_PFX+"Edit_SLp"||sp==PNL_PFX+"Edit_TPp") RecalcLinesFromPanel();
    }

    // ── Clics en botones ─────────────────────────────────────────
    if(id==CHARTEVENT_OBJECT_CLICK)
    {
        HandleClick(sp);
        if(ObjectFind(0,sp)>=0&&ObjectGetInteger(0,sp,OBJPROP_TYPE)==OBJ_BUTTON)
            ObjectSetInteger(0,sp,OBJPROP_STATE,false);
    }

    ChartRedraw();
}
//+------------------------------------------------------------------+
