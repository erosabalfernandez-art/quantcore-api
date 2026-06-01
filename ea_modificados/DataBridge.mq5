//+------------------------------------------------------------------+
  //|                                              DataBridge.mq5      |
  //|                        FlowTrade Suite — Data Bridge EA v3       |
  //|   Única forma de conectar tu MT5 a FlowTrade Suite.             |
  //|   La cuenta MT5 queda vinculada permanentemente al token.        |
  //|   No puede usarse en otras cuentas ni compartirse.              |
  //+------------------------------------------------------------------+
  #property copyright "FlowTrade Suite"
  #property link      "https://samtrader.pro"
  #property version   "3.00"
  #property description "Conecta tu cuenta MT5 a FlowTrade Suite."
  #property description "Vincula permanentemente tu cuenta al token de licencia."
  #property description "No puede usarse en otras cuentas ni compartirse."

  input string LicenseToken        = "";                                        // ← Pega aquí tu Token de Licencia
  input string ApiUrl              = "https://quantcore-api.vercel.app/api/";  // URL de la API (no modificar)
  input int    SendIntervalSeconds = 3600;                                      // Intervalo de envío en segundos
  input bool   SendOnInit          = true;                                      // Enviar al iniciar el EA

  bool g_validated  = false;
  bool g_initSent   = false;
  string g_hwid     = "";

  //+------------------------------------------------------------------+
  int OnInit()
  {
     if(LicenseToken == "")
     {
        Alert("DataBridge v3: Ingresa tu LicenseToken en los parámetros del EA.\n"
              "Cópialo desde tu perfil en FlowTrade Suite (menú lateral → Token MT5).");
        return INIT_FAILED;
     }

     // Generar HWID: combinación de cuenta + servidor + path terminal
     string termPath = TerminalInfoString(TERMINAL_PATH);
     long   account  = AccountInfoInteger(ACCOUNT_LOGIN);
     string server   = AccountInfoString(ACCOUNT_SERVER);
     g_hwid = StringFormat("MT5_%I64d_%s_%d", account, server, StringLen(termPath));

     Print("=== DataBridge v3.0 iniciado ===");
     Print("Token   : ", StringSubstr(LicenseToken, 0, 8), "...");
     Print("Cuenta  : ", account);
     Print("Servidor: ", server);
     Print("HWID    : ", g_hwid);

     // Validar licencia ANTES de hacer nada más
     if(!ValidateLicense())
     {
        Alert("DataBridge v3: Licencia no válida. Verifica tu token en FlowTrade Suite.\n"
              "Si crees que es un error, contacta al administrador.");
        return INIT_FAILED;
     }

     g_validated = true;
     EventSetTimer(SendIntervalSeconds);
     if(SendOnInit) { EventSetTimer(5); g_initSent = false; }
     return INIT_SUCCEEDED;
  }

  //+------------------------------------------------------------------+
  void OnDeinit(const int reason)
  {
     EventKillTimer();
     Print("DataBridge v3 detenido. Motivo: ", reason);
  }

  //+------------------------------------------------------------------+
  void OnTimer()
  {
     if(!g_validated) return;

     if(!g_initSent)
     {
        g_initSent = true;
        EventKillTimer();
        EventSetTimer(SendIntervalSeconds);
     }
     SendClosedTrades();
     SendSymbolSpecs();
  }

  //+------------------------------------------------------------------+
  void OnTrade()
  {
     if(!g_validated) return;
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
  //| Valida la licencia contra el servidor. Vincula la cuenta MT5.   |
  //| Retorna true si la licencia es válida, false si no.             |
  //+------------------------------------------------------------------+
  bool ValidateLicense()
  {
     string url = BuildUrl("validar-licencia");
     string body = StringFormat(
        "{\"token\":\"%s\",\"ea_tipo\":\"data_bridge\","
        "\"mt5_account\":\"%I64d\",\"version_ea\":\"3.0\","
        "\"hwid\":\"%s\"}",
        LicenseToken,
        AccountInfoInteger(ACCOUNT_LOGIN),
        g_hwid
     );

     char   reqData[], resData[];
     string resHeaders;
     int reqSize = StringToCharArray(body, reqData, 0, WHOLE_ARRAY, CP_UTF8) - 1;
     ArrayResize(reqData, reqSize);
     string headers = "Content-Type: application/json\r\nAccept: application/json\r\n";

     ResetLastError();
     int httpCode = WebRequest("POST", url, headers, 15000, reqData, resData, resHeaders);

     if(httpCode == -1)
     {
        int err = GetLastError();
        if(err == 4014)
           Alert("DataBridge v3: Añade esta URL en MT5 → Herramientas → Opciones → Expert Advisors → WebRequest:\n"
                 + StringSubstr(url, 0, StringFind(url, "/api/") + 1));
        else
           Print("DataBridge v3: Error WebRequest #", err, " al validar licencia");
        return false;
     }

     string response = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);
     Print("DataBridge v3: Validación HTTP ", httpCode, " — ", StringSubstr(response, 0, 200));

     if(httpCode == 200)
     {
        // Extraer mensaje de bienvenida
        int posUsuario = StringFind(response, "\"usuario\":\"");
        if(posUsuario >= 0)
        {
           posUsuario += 10;
           int posEnd = StringFind(response, "\"", posUsuario + 1);
           string nombre = StringSubstr(response, posUsuario, posEnd - posUsuario);
           Print("DataBridge v3: ✓ Licencia válida — Usuario: ", nombre, " — Cuenta vinculada: ",
                 AccountInfoInteger(ACCOUNT_LOGIN));
        }
        return true;
     }
     else
     {
        // Extraer motivo del error
        int posMotivo = StringFind(response, "\"motivo\":\"");
        if(posMotivo >= 0)
        {
           posMotivo += 10;
           int posEnd = StringFind(response, "\"", posMotivo + 1);
           string motivo = StringSubstr(response, posMotivo, posEnd - posMotivo);
           Print("DataBridge v3: ✗ Licencia inválida — Motivo: ", motivo);
           Alert("DataBridge v3 — Licencia rechazada:\n" + motivo);
        }
        return false;
     }
  }

  //+------------------------------------------------------------------+
  void SendSymbolSpecs()
  {
     string symbols[];
     int symCount = 0;

     ArrayResize(symbols, 1);
     symbols[0] = Symbol();
     symCount = 1;

     int posTotal = PositionsTotal();
     for(int i = 0; i < posTotal && symCount < 60; i++)
     {
        string sym = PositionGetSymbol(i);
        if(sym == "") continue;
        bool found = false;
        for(int j = 0; j < symCount; j++) if(symbols[j] == sym) { found = true; break; }
        if(!found) { ArrayResize(symbols, symCount+1); symbols[symCount++] = sym; }
     }

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
           for(int j = 0; j < symCount; j++) if(symbols[j] == sym) { found = true; break; }
           if(!found) { ArrayResize(symbols, symCount+1); symbols[symCount++] = sym; }
        }
     }

     if(symCount == 0) return;

     string symbolsJson = "[";
     bool firstSym = true;

     for(int i = 0; i < symCount; i++)
     {
        string sym = symbols[i];
        double tickSize   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
        double tickValue  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
        double contractSz = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
        double pointSize  = SymbolInfoDouble(sym, SYMBOL_POINT);
        int    digits     = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
        double pipSize    = pointSize * 10.0;
        double pipValue   = (tickSize > 0.0) ? (pipSize / tickSize) * tickValue : 0.0;

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

     string body = StringFormat(
        "{\"token\":\"%s\",\"cuenta\":\"%I64d\",\"simbolos\":%s}",
        LicenseToken, AccountInfoInteger(ACCOUNT_LOGIN), symbolsJson
     );

     char reqData[], resData[];
     string resHeaders;
     int reqSize = StringToCharArray(body, reqData, 0, WHOLE_ARRAY, CP_UTF8) - 1;
     ArrayResize(reqData, reqSize);
     string hdrs = "Content-Type: application/json\r\nAccept: application/json\r\n";

     int httpCode = WebRequest("POST", BuildUrl("recibir-simbolos"), hdrs, 10000, reqData, resData, resHeaders);
     if(httpCode == 200 || httpCode == 201)
        Print("DataBridge v3: ✓ Símbolos enviados — ", symCount, " activos");
     else
        Print("DataBridge v3: Símbolos HTTP ", httpCode, " — ", StringSubstr(CharArrayToString(resData), 0, 120));
  }

  //+------------------------------------------------------------------+
  void SendClosedTrades()
  {
     if(!HistorySelect(0, TimeCurrent())) { Print("DataBridge v3: Error al seleccionar historial"); return; }
     int total = HistoryDealsTotal();
     if(total == 0) { Print("DataBridge v3: Sin historial de deals."); return; }

     string url = BuildUrl("recibir-trades");
     string batchJson = "[";
     int count = 0, batchNum = 0;
     bool firstItem = true;

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

        double openPrice = 0; datetime openTime = 0;
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
           double pipSize = (digits == 3 || digits == 5 || digits == 2 || digits == 4) ? 0.0001 : 0.01;
           if(digits == 2 || digits == 3) pipSize = 0.01;
           double diff = (dealType == DEAL_TYPE_BUY) ? (closePrice - openPrice) : (openPrice - closePrice);
           pips = diff / pipSize;
        }

        string tradeEntry = StringFormat(
           "{\"ticket\":%I64u,\"position_id\":%I64u,"
           "\"fecha\":\"%s\",\"fecha_apertura\":\"%s\","
           "\"activo\":\"%s\",\"tipo\":\"%s\","
           "\"lotes\":%.2f,\"precio_entrada\":%.5f,\"precio_salida\":%.5f,"
           "\"resultado_usd\":%.2f,\"pips\":%.1f}",
           ticket, posId,
           TimeToString(closeTime, TIME_DATE|TIME_MINUTES),
           TimeToString(openTime,  TIME_DATE|TIME_MINUTES),
           symbol, (dealType == DEAL_TYPE_BUY ? "Compra" : "Venta"),
           lots, openPrice, closePrice,
           profit + swap + commission, pips
        );

        if(!firstItem) batchJson += ",";
        batchJson += tradeEntry;
        firstItem = false;
        count++;

        if(count >= 20)
        {
           batchJson += "]";
           batchNum++;
           Print("DataBridge v3: Enviando lote #", batchNum, " (", count, " trades)...");
           if(!PostBatch(url, batchJson)) Print("DataBridge v3: Fallo en lote #", batchNum);
           Sleep(500);
           batchJson = "["; count = 0; firstItem = true;
        }
     }

     if(count > 0)
     {
        batchJson += "]"; batchNum++;
        Print("DataBridge v3: Enviando lote #", batchNum, " (", count, " trades)...");
        PostBatch(url, batchJson);
     }

     if(batchNum == 0) Print("DataBridge v3: No hay trades cerrados para enviar.");
     else Print("DataBridge v3: ✓ Envío completado. Lotes: ", batchNum);
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

     char reqData[], resData[];
     string resHeaders;
     int reqSize = StringToCharArray(body, reqData, 0, WHOLE_ARRAY, CP_UTF8) - 1;
     ArrayResize(reqData, reqSize);
     string hdrs = "Content-Type: application/json\r\nAccept: application/json\r\n";

     ResetLastError();
     int httpCode = WebRequest("POST", url, hdrs, 10000, reqData, resData, resHeaders);
     if(httpCode == -1)
     {
        Print("DataBridge v3: Error WebRequest #", GetLastError());
        return false;
     }
     string resp = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);
     if(httpCode == 200 || httpCode == 201) { Print("DataBridge v3: ✓ HTTP ", httpCode, " — ", StringSubstr(resp,0,120)); return true; }
     Print("DataBridge v3: ✗ HTTP ", httpCode, " — ", StringSubstr(resp,0,200));
     return false;
  }
  //+------------------------------------------------------------------+
  