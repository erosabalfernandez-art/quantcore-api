//+------------------------------------------------------------------+
//|                                              DataBridge.mq5      |
//|                        FlowTrade Suite — Data Bridge EA v2       |
//|   Envía historial de trades cerrados + especificaciones de       |
//|   símbolos a la plataforma FlowTrade Suite.                      |
//+------------------------------------------------------------------+
#property copyright "FlowTrade Suite"
#property link      "https://samtrader.pro"
#property version   "2.00"
#property description "Envía el historial de trades cerrados a FlowTrade Suite."
#property description "v2: también envía especificaciones exactas de símbolos"
#property description "(pip_value, tick_value, contract_size) para la Calculadora MT5 Personal."
#property description "No toma capturas. Solo transfiere datos."

//--- Parámetros externos
input string LicenseToken        = "";                                        // Token de licencia (cópialo desde tu perfil)
input string ApiUrl              = "https://quantcore-api.vercel.app/api/";  // URL base de la API
input int    SendIntervalSeconds = 3600;                                      // Intervalo de envío (segundos)
input bool   SendOnInit          = true;                                      // Enviar al iniciar

//--- Estado interno
bool g_initSent = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(LicenseToken == "")
   {
      Alert("DataBridge v2: Ingresa tu LicenseToken en los parámetros del EA.");
      return INIT_FAILED;
   }
   Print("=== DataBridge v2.0 iniciado ===");
   Print("API URL : ", BuildUrl("recibir-trades"));
   Print("Token   : ", StringSubstr(LicenseToken, 0, 8), "...");
   Print("Cuenta  : ", AccountInfoInteger(ACCOUNT_LOGIN));

   EventSetTimer(SendIntervalSeconds);
   if(SendOnInit)
   {
      EventSetTimer(5);
      g_initSent = false;
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("DataBridge v2 detenido.");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_initSent)
   {
      g_initSent = true;
      EventKillTimer();
      EventSetTimer(SendIntervalSeconds);
   }
   SendClosedTrades();
   SendSymbolSpecs();   // ← NUEVO en v2
}

//+------------------------------------------------------------------+
void OnTrade()
{
   EventKillTimer();
   EventSetTimer(3);
   g_initSent = true;
}

//+------------------------------------------------------------------+
string BuildUrl(const string endpoint)
{
   string url = ApiUrl;
   if(StringLen(url) > 0 && StringSubstr(url, StringLen(url)-1) != "/")
      url += "/";
   return url + endpoint;
}

//+------------------------------------------------------------------+
//| Envía especificaciones de símbolos al servidor                   |
//| Endpoint: /api/recibir-simbolos                                  |
//+------------------------------------------------------------------+
void SendSymbolSpecs()
{
   string symbols[];
   int    symCount = 0;

   // 1. Símbolo del gráfico activo
   ArrayResize(symbols, 1);
   symbols[0] = Symbol();
   symCount    = 1;

   // 2. Símbolos de posiciones abiertas
   int posTotal = PositionsTotal();
   for(int i = 0; i < posTotal && symCount < 60; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym == "") continue;
      bool found = false;
      for(int j = 0; j < symCount; j++)
         if(symbols[j] == sym) { found = true; break; }
      if(!found) { ArrayResize(symbols, symCount+1); symbols[symCount++] = sym; }
   }

   // 3. Símbolos del historial de deals
   if(HistorySelect(0, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      for(int i = MathMax(0, total-500); i < total && symCount < 60; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(sym == "") continue;
         bool found = false;
         for(int j = 0; j < symCount; j++)
            if(symbols[j] == sym) { found = true; break; }
         if(!found) { ArrayResize(symbols, symCount+1); symbols[symCount++] = sym; }
      }
   }

   if(symCount == 0) return;

   // 4. Construir JSON con specs de cada símbolo
   string symbolsJson = "[";
   bool firstSym = true;

   for(int i = 0; i < symCount; i++)
   {
      string sym = symbols[i];

      double tickSize    = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tickValue   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double contractSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
      double pointSize   = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    digits      = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

      // Calcular pip_value:
      //   Para la mayoría de forex de 5 dígitos: 1 pip = 10 ticks
      //   pip_value = tick_value * (pip_size / tick_size)
      double pipSize = pointSize;
      if(digits == 5 || digits == 3) pipSize = pointSize * 10.0;   // forex y JPY
      else if(digits == 4 || digits == 2) pipSize = pointSize * 10.0;
      else pipSize = pointSize * 10.0;                             // genérico

      double pipValue = (tickSize > 0.0) ? (pipSize / tickSize) * tickValue : 0.0;

      string symEntry = StringFormat(
         "{\"simbolo\":\"%s\",\"tick_size\":%.8f,\"tick_value\":%.8f,"
         "\"contract_size\":%.4f,\"point\":%.8f,\"digits\":%d,\"pip_value\":%.8f}",
         sym, tickSize, tickValue, contractSz, pointSize, digits, pipValue
      );

      if(!firstSym) symbolsJson += ",";
      symbolsJson += symEntry;
      firstSym = false;
   }
   symbolsJson += "]";

   // 5. Armar body y POST
   string body = StringFormat(
      "{\"token\":\"%s\",\"cuenta\":\"%I64d\",\"simbolos\":%s}",
      LicenseToken,
      AccountInfoInteger(ACCOUNT_LOGIN),
      symbolsJson
   );

   char   reqData[];
   char   resData[];
   string resHeaders;
   int reqSize = StringToCharArray(body, reqData, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(reqData, reqSize);
   string headers = "Content-Type: application/json\r\nAccept: application/json\r\n";

   ResetLastError();
   string urlSyms = BuildUrl("recibir-simbolos");
   int httpCode   = WebRequest("POST", urlSyms, headers, 10000, reqData, resData, resHeaders);

   if(httpCode == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Print("DataBridge v2: Añade la URL a WebRequest permitidas: Herramientas → Opciones → Expert Advisors");
      else
         Print("DataBridge v2: Error WebRequest #", err);
      return;
   }

   if(httpCode == 200 || httpCode == 201)
      Print("DataBridge v2: ✓ Símbolos enviados — ", symCount, " activos");
   else
   {
      string response = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);
      Print("DataBridge v2: Símbolos — HTTP ", httpCode, " — ", StringSubstr(response, 0, 150));
   }
}

//+------------------------------------------------------------------+
//| Recorre el historial y envía trades cerrados en lotes de 20      |
//+------------------------------------------------------------------+
void SendClosedTrades()
{
   if(!HistorySelect(0, TimeCurrent()))
   {
      Print("DataBridge v2: Error al seleccionar historial - código: ", GetLastError());
      return;
   }

   int total = HistoryDealsTotal();
   if(total == 0)
   {
      Print("DataBridge v2: Sin historial de deals.");
      return;
   }

   string url       = BuildUrl("recibir-trades");
   string batchJson = "[";
   int    count     = 0;
   bool   firstItem = true;
   int    batchNum  = 0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) continue;

      datetime closeTime  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      string   symbol     = HistoryDealGetString(ticket, DEAL_SYMBOL);
      double   lots       = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double   closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
      double   profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double   swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double   commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      ulong    posId      = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);

      double openPrice = 0;
      datetime openTime = 0;
      for(int j = 0; j < total; j++)
      {
         ulong t2 = HistoryDealGetTicket(j);
         if(t2 == 0) continue;
         if((ulong)HistoryDealGetInteger(t2, DEAL_POSITION_ID) != posId) continue;
         ENUM_DEAL_ENTRY e2 = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(t2, DEAL_ENTRY);
         if(e2 == DEAL_ENTRY_IN || e2 == DEAL_ENTRY_INOUT)
         {
            openPrice = HistoryDealGetDouble(t2, DEAL_PRICE);
            openTime  = (datetime)HistoryDealGetInteger(t2, DEAL_TIME);
            break;
         }
      }

      double pips = 0;
      if(openPrice > 0 && closePrice > 0)
      {
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         double pipSize = (digits == 3 || digits == 5) ? 0.0001 : 0.01;
         if(digits == 2 || digits == 3) pipSize = 0.01;
         double diff = (dealType == DEAL_TYPE_BUY) ? (closePrice - openPrice) : (openPrice - closePrice);
         pips = diff / pipSize;
      }

      double netResult = profit + swap + commission;
      string tipo      = (dealType == DEAL_TYPE_BUY) ? "Compra" : "Venta";

      string tradeEntry = StringFormat(
         "{\"ticket\":%I64u,\"position_id\":%I64u,"
         "\"fecha\":\"%s\",\"fecha_apertura\":\"%s\","
         "\"activo\":\"%s\",\"tipo\":\"%s\","
         "\"lotes\":%.2f,\"precio_entrada\":%.5f,\"precio_salida\":%.5f,"
         "\"resultado_usd\":%.2f,\"pips\":%.1f}",
         ticket, posId,
         TimeToString(closeTime, TIME_DATE | TIME_MINUTES),
         TimeToString(openTime,  TIME_DATE | TIME_MINUTES),
         symbol, tipo,
         lots, openPrice, closePrice,
         netResult, pips
      );

      if(!firstItem) batchJson += ",";
      batchJson += tradeEntry;
      firstItem = false;
      count++;

      if(count >= 20)
      {
         batchJson += "]";
         batchNum++;
         Print("DataBridge v2: Enviando lote #", batchNum, " (", count, " trades)...");
         if(!PostBatch(url, batchJson))
            Print("DataBridge v2: Fallo en lote #", batchNum, ". Se reintentará.");
         Sleep(500);
         batchJson = "[";
         count     = 0;
         firstItem = true;
      }
   }

   if(count > 0)
   {
      batchJson += "]";
      batchNum++;
      Print("DataBridge v2: Enviando lote #", batchNum, " (", count, " trades)...");
      PostBatch(url, batchJson);
   }

   if(batchNum == 0)
      Print("DataBridge v2: No hay trades cerrados para enviar.");
   else
      Print("DataBridge v2: Envío completado. Lotes enviados: ", batchNum);
}

//+------------------------------------------------------------------+
bool PostBatch(const string url, const string tradesJson)
{
   string body = StringFormat(
      "{\"token\":\"%s\",\"cuenta\":\"%I64d\",\"servidor\":\"%s\",\"trades\":%s}",
      LicenseToken,
      AccountInfoInteger(ACCOUNT_LOGIN),
      AccountInfoString(ACCOUNT_SERVER),
      tradesJson
   );

   char   reqData[];
   char   resData[];
   string resHeaders;
   int reqSize = StringToCharArray(body, reqData, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(reqData, reqSize);
   string headers = "Content-Type: application/json\r\nAccept: application/json\r\n";

   ResetLastError();
   int httpCode = WebRequest("POST", url, headers, 10000, reqData, resData, resHeaders);

   if(httpCode == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Print("DataBridge v2: URL no permitida. Añádela en Herramientas → Opciones → Expert Advisors → WebRequest: ", StringSubstr(url,0,StringFind(url,"/api/")+1));
      else
         Print("DataBridge v2: Error WebRequest #", err);
      return false;
   }

   string response = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);
   if(httpCode == 200 || httpCode == 201)
   {
      Print("DataBridge v2: ✓ HTTP ", httpCode, " — ", StringSubstr(response, 0, 120));
      return true;
   }
   else
   {
      Print("DataBridge v2: ✗ HTTP ", httpCode, " — ", StringSubstr(response, 0, 200));
      return false;
   }
}
//+------------------------------------------------------------------+
