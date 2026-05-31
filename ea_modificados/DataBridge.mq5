//+------------------------------------------------------------------+
//|                                              DataBridge.mq5      |
//|                        Samtrader Pro Suite — Data Bridge EA      |
//|      Envía historial de trades cerrados a la plataforma          |
//+------------------------------------------------------------------+
#property copyright "Samtrader Pro Suite"
#property link      "https://samtrader.pro"
#property version   "1.00"
#property description "Envía el historial de trades cerrados a Samtrader Pro Suite."
#property description "No toma capturas. Solo transfiere datos."

//--- Parámetros externos
input string LicenseToken = "";                                           // Token de licencia (cópialo desde tu perfil)
input string ApiUrl       = "https://quantcore-api.vercel.app/api/";     // URL base de la API
input int    SendIntervalSeconds = 3600;                                  // Intervalo de envío (segundos)
input bool   SendOnInit   = true;                                         // Enviar historial completo al iniciar

//--- Estado interno
bool g_initSent = false;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(LicenseToken == "")
   {
      Alert("DataBridge: Debes ingresar tu LicenseToken en los parámetros del EA.");
      return INIT_FAILED;
   }

   Print("=== DataBridge v1.0 iniciado ===");
   Print("API URL : ", BuildUrl());
   Print("Token   : ", StringSubstr(LicenseToken, 0, 8), "...");
   Print("Cuenta  : ", AccountInfoInteger(ACCOUNT_LOGIN));

   EventSetTimer(SendIntervalSeconds);

   if(SendOnInit)
   {
      // Envío inicial diferido 5 s para que MT5 termine de cargar
      EventSetTimer(5);
      g_initSent = false;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("DataBridge detenido.");
}

//+------------------------------------------------------------------+
//| Timer                                                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_initSent)
   {
      g_initSent = true;
      // Restaurar intervalo normal
      EventKillTimer();
      EventSetTimer(SendIntervalSeconds);
   }
   SendClosedTrades();
}

//+------------------------------------------------------------------+
//| Detecta nuevas operaciones cerradas en tiempo real               |
//+------------------------------------------------------------------+
void OnTrade()
{
   // Disparar envío a los 3 s para no saturar en ráfagas
   EventKillTimer();
   EventSetTimer(3);
   g_initSent = true;   // ya habremos enviado el init
}

//+------------------------------------------------------------------+
//| Construye la URL completa del endpoint                           |
//+------------------------------------------------------------------+
string BuildUrl()
{
   string url = ApiUrl;
   if(StringLen(url) > 0 && StringSubstr(url, StringLen(url)-1) != "/")
      url += "/";
   return url + "recibir-trades";
}

//+------------------------------------------------------------------+
//| Recorre el historial y envía trades cerrados en lotes de 20      |
//+------------------------------------------------------------------+
void SendClosedTrades()
{
   if(!HistorySelect(0, TimeCurrent()))
   {
      Print("DataBridge: Error al seleccionar historial - código: ", GetLastError());
      return;
   }

   int total = HistoryDealsTotal();
   if(total == 0)
   {
      Print("DataBridge: Sin historial de deals.");
      return;
   }

   string url       = BuildUrl();
   string batchJson = "[";
   int    count     = 0;
   bool   firstItem = true;
   int    batchNum  = 0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      // Solo deals de cierre
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      // Solo Buy/Sell (descartar depósitos, créditos, etc.)
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

      // Buscar precio de apertura del mismo position_id
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

      // Calcular pips
      double pips = 0;
      if(openPrice > 0 && closePrice > 0)
      {
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         double pipSize = (digits == 3 || digits == 5) ? 0.0001 : 0.01;
         // Para JPY y otros de 2 decimales pip = 0.01
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

      // Enviar lote de 20 y reiniciar
      if(count >= 20)
      {
         batchJson += "]";
         batchNum++;
         Print("DataBridge: Enviando lote #", batchNum, " (", count, " trades)...");
         if(!PostBatch(url, batchJson))
            Print("DataBridge: Fallo en lote #", batchNum, ". Se reintentará en el próximo ciclo.");
         Sleep(500);
         batchJson = "[";
         count     = 0;
         firstItem = true;
      }
   }

   // Último lote parcial
   if(count > 0)
   {
      batchJson += "]";
      batchNum++;
      Print("DataBridge: Enviando lote #", batchNum, " (", count, " trades)...");
      PostBatch(url, batchJson);
   }

   if(batchNum == 0)
      Print("DataBridge: No hay trades cerrados para enviar.");
   else
      Print("DataBridge: Envío completado. Lotes enviados: ", batchNum);
}

//+------------------------------------------------------------------+
//| POST de un lote JSON al endpoint                                 |
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
         Print("DataBridge: URL no permitida. Ve a Herramientas → Opciones → Expert Advisors → WebRequest y añade: ", StringSubstr(url, 0, StringFind(url, "/api/")+1));
      else
         Print("DataBridge: Error WebRequest #", err);
      return false;
   }

   string response = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);

   if(httpCode == 200 || httpCode == 201)
   {
      Print("DataBridge: ✓ HTTP ", httpCode, " — ", StringSubstr(response, 0, 120));
      return true;
   }
   else
   {
      Print("DataBridge: ✗ HTTP ", httpCode, " — ", StringSubstr(response, 0, 200));
      return false;
   }
}
//+------------------------------------------------------------------+
