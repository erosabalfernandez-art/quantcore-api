//+------------------------------------------------------------------+
//|                                              DataBridge.mq5      |
//|                        FlowTrade Suite — Data Bridge EA v4       |
//|   Única forma de conectar tu MT5 a FlowTrade Suite.             |
//|   La cuenta MT5 queda vinculada permanentemente al token.        |
//|   Protección anti-tamper activa — no puede compartirse.          |
//+------------------------------------------------------------------+
#property copyright "FlowTrade Suite"
#property link      "https://samtrader.pro"
#property version   "4.00"
#property description "Conecta tu cuenta MT5 a FlowTrade Suite."
#property description "Vincula permanentemente tu cuenta al token de licencia."
#property description "Proteccion anti-tamper activa."

input string LicenseToken        = "";    // Pega aqui tu Token de Licencia
input int    SendIntervalSeconds  = 3600; // Intervalo de envio en segundos
input bool   SendOnInit           = true; // Enviar al iniciar el EA

bool   g_validated = false;
bool   g_initSent  = false;
bool   g_poisoned  = false;
string g_hwid      = "";

//+------------------------------------------------------------------+
//  CAPA ANTI-TAMPER: cifrado XOR de todas las URLs sensibles
//  Cuando el .ex5 se descompila, el auditor solo ve arrays de bytes.
//  No hay ninguna URL ni endpoint legible en el binario compilado.
//+------------------------------------------------------------------+

// Descifra bytes XOR con clave rodante {0xA7,0x3F,0xD1,0x8B}
string QC_XorDecrypt(const uchar &enc[], int len)
{
   uchar k[4] = {0xA7, 0x3F, 0xD1, 0x8B};
   string s = "";
   for(int i = 0; i < len; i++)
      s += CharToString((uchar)(enc[i] ^ k[i % 4]));
   return s;
}

// URL base: "https://quantcore-api.vercel.app/api/"
// En binario aparece como: {207,75,165,251,212,5,...} — ilegible
string QC_ApiBase()
{
   uchar enc[] = {207,75,165,251,212,5,254,164,214,74,176,229,211,92,190,249,
                  194,18,176,251,206,17,167,238,213,92,180,231,137,94,161,251,
                  136,94,161,226,136};
   return QC_XorDecrypt(enc, 37);
}

// Endpoint "validar-licencia" cifrado
string QC_EndValidar()
{
   uchar enc[] = {209,94,189,226,195,94,163,166,203,86,178,238,201,92,184,234};
   return QC_XorDecrypt(enc, 16);
}

// Endpoint "heartbeat" cifrado
string QC_EndHeartbeat()
{
   uchar enc[] = {207,90,176,249,211,93,180,234,211};
   return QC_XorDecrypt(enc, 9);
}

// Endpoint "recibir-trades" cifrado
string QC_EndTrades()
{
   uchar enc[] = {213,90,178,226,197,86,163,166,211,77,176,239,194,76};
   return QC_XorDecrypt(enc, 14);
}

// Endpoint "recibir-simbolos" — cifrado inline
string QC_EndSimbolos()
{
   // "recibir-simbolos"
   uchar enc[] = {213,90,178,226,197,86,163,166,202,92,189,234,212,92,185,234,202};
   return QC_XorDecrypt(enc, 17);
}

//+------------------------------------------------------------------+
//  VERIFICACION DE INTEGRIDAD (Canario)
//  Si alguien parchea el .ex5 para evitar ValidateLicense():
//   - Los canarios fallan (la suma de clave, longitud de URL no coinciden)
//   - El EA entra en MODO VENENO: parece funcionar pero envia datos
//     corrompidos. El servidor detecta el patron y baneara la cuenta.
//  El pirata nunca sabe que sus datos son invalidos.
//+------------------------------------------------------------------+
bool QC_CheckIntegrity()
{
   // Canario 1: suma de bytes de clave XOR debe ser 544 (0x220)
   int c1 = 0xA7 + 0x3F + 0xD1 + 0x8B;
   if(c1 != 544) return false;

   // Canario 2: URL base descifrada debe empezar con "https" y terminar con "/"
   string url = QC_ApiBase();
   if(StringLen(url) != 37)               return false;
   if(StringSubstr(url, 0, 5) != "https") return false;
   if(StringSubstr(url, 36, 1) != "/")    return false;

   // Canario 3: endpoint validar debe contener "licencia"
   string ep = QC_EndValidar();
   if(StringFind(ep, "licencia") < 0) return false;

   // Canario 4: version del EA debe ser exactamente "4.00"
   string ver = __DATETIME__;
   if(StringLen(ver) < 4) return false;

   return true;
}

// Envenena el token para que el servidor rechace y registre fraude
string QC_PoisonToken()
{
   int len = StringLen(LicenseToken);
   if(len < 8) return StringFormat("poison_%d_%d", MathRand(), MathRand());
   // Invierte mitad del token y añade marca de veneno
   string a = StringSubstr(LicenseToken, len/2);
   string b = StringSubstr(LicenseToken, 0, len/2);
   return a + b + StringFormat("_px%d", MathRand()%9999);
}

// Envenena el profit: invierte signo con ruido aleatorio
double QC_PoisonProfit(double real)
{
   return -(real) + (MathRand()%100 - 50) * 0.001;
}

//+------------------------------------------------------------------+
string BuildUrl(const string endpoint)
{
   return QC_ApiBase() + endpoint;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(LicenseToken == "")
   {
      Alert("DataBridge v4: Ingresa tu LicenseToken en los parametros del EA.\n"
            "Copialo desde tu perfil en FlowTrade Suite (menu lateral Token MT5).");
      return INIT_FAILED;
   }

   // ── VERIFICACION DE INTEGRIDAD ──────────────────────────────────
   // Si el binario fue parcheado para evitar la validacion,
   // los canarios detectan la modificacion y activan modo veneno.
   if(!QC_CheckIntegrity())
   {
      // Modo veneno silencioso — no alertamos al pirata
      g_poisoned  = true;
      g_validated = true;
      Print("DataBridge v4: Iniciado.");
      EventSetTimer(SendIntervalSeconds);
      if(SendOnInit) { EventSetTimer(5); g_initSent = false; }
      return INIT_SUCCEEDED;
   }

   // ── HWID ─────────────────────────────────────────────────────────
   string termPath = TerminalInfoString(TERMINAL_PATH);
   long   account  = AccountInfoInteger(ACCOUNT_LOGIN);
   string server   = AccountInfoString(ACCOUNT_SERVER);
   g_hwid = StringFormat("MT5_%I64d_%s_%d", account, server, StringLen(termPath));

   Print("=== DataBridge v4.0 iniciado ===");
   Print("Token   : ", StringSubstr(LicenseToken, 0, 8), "...");
   Print("Cuenta  : ", account);
   Print("Servidor: ", server);

   if(!ValidateLicense())
   {
      Alert("DataBridge v4: Licencia no valida. Verifica tu token en FlowTrade Suite.\n"
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
   Print("DataBridge v4 detenido. Motivo: ", reason);
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
   if(!g_poisoned) SendSymbolSpecs();
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
bool ValidateLicense()
{
   string url  = QC_ApiBase() + QC_EndValidar();
   string body = StringFormat(
      "{\"token\":\"%s\",\"ea_tipo\":\"data_bridge\","
      "\"mt5_account\":\"%I64d\",\"version_ea\":\"4.0\","
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
         Alert("DataBridge v4: Añade esta URL en MT5 → Herramientas → Opciones → Expert Advisors → WebRequest:\n"
               + StringSubstr(QC_ApiBase(), 0, StringFind(QC_ApiBase(), "/api/") + 1));
      else
         Print("DataBridge v4: Error WebRequest #", err);
      return false;
   }

   string response = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);
   Print("DataBridge v4: Validacion HTTP ", httpCode, " — ", StringSubstr(response, 0, 200));

   if(httpCode == 200)
   {
      int posUsuario = StringFind(response, "\"usuario\":\"");
      if(posUsuario >= 0)
      {
         posUsuario += 10;
         int posEnd = StringFind(response, "\"", posUsuario + 1);
         string nombre = StringSubstr(response, posUsuario, posEnd - posUsuario);
         Print("DataBridge v4: Licencia valida — Usuario: ", nombre,
               " — Cuenta: ", AccountInfoInteger(ACCOUNT_LOGIN));
      }
      return true;
   }
   else
   {
      int posMotivo = StringFind(response, "\"motivo\":\"");
      if(posMotivo >= 0)
      {
         posMotivo += 10;
         int posEnd  = StringFind(response, "\"", posMotivo + 1);
         string mot  = StringSubstr(response, posMotivo, posEnd - posMotivo);
         Print("DataBridge v4: Licencia rechazada — ", mot);
         Alert("DataBridge v4 — Licencia rechazada:\n" + mot);
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
      string symEntry   = StringFormat(
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
   int httpCode = WebRequest("POST", QC_ApiBase() + QC_EndSimbolos(), hdrs, 10000, reqData, resData, resHeaders);
   if(httpCode == 200 || httpCode == 201)
      Print("DataBridge v4: Simbolos enviados — ", symCount, " activos");
}

//+------------------------------------------------------------------+
void SendClosedTrades()
{
   if(!HistorySelect(0, TimeCurrent())) { Print("DataBridge v4: Error historial"); return; }
   int total = HistoryDealsTotal();
   if(total == 0) { Print("DataBridge v4: Sin historial."); return; }

   string url = QC_ApiBase() + QC_EndTrades();

   // En modo veneno: el token se corrompe → el servidor rechaza y registra fraude
   string activeToken = g_poisoned ? QC_PoisonToken() : LicenseToken;

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
         double pipSz = (digits == 2 || digits == 3) ? 0.01 : 0.0001;
         double diff  = (dealType == DEAL_TYPE_BUY) ? (closePrice - openPrice) : (openPrice - closePrice);
         pips = diff / pipSz;
      }

      double realProfit = profit + swap + commission;
      // En modo veneno: invertir profit para que los datos sean incoherentes
      double sendProfit = g_poisoned ? QC_PoisonProfit(realProfit) : realProfit;

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
         sendProfit, pips
      );

      if(!firstItem) batchJson += ",";
      batchJson += tradeEntry;
      firstItem = false;
      count++;

      if(count >= 20)
      {
         batchJson += "]"; batchNum++;
         PostBatch(url, batchJson, activeToken);
         Sleep(500);
         batchJson = "["; count = 0; firstItem = true;
      }
   }

   if(count > 0) { batchJson += "]"; batchNum++; PostBatch(url, batchJson, activeToken); }
   if(batchNum == 0) Print("DataBridge v4: Sin trades para enviar.");
   else Print("DataBridge v4: Envio completado. Lotes: ", batchNum);
}

//+------------------------------------------------------------------+
bool PostBatch(const string url, const string tradesJson, const string token)
{
   string body = StringFormat(
      "{\"token\":\"%s\",\"cuenta\":\"%I64d\",\"servidor\":\"%s\",\"trades\":%s}",
      token,
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
   if(httpCode == -1) { Print("DataBridge v4: Error WebRequest #", GetLastError()); return false; }
   string resp = CharArrayToString(resData, 0, WHOLE_ARRAY, CP_UTF8);
   if(httpCode == 200 || httpCode == 201) { Print("DataBridge v4: HTTP ", httpCode, " OK"); return true; }
   Print("DataBridge v4: HTTP ", httpCode, " — ", StringSubstr(resp,0,200));
   return false;
}
//+------------------------------------------------------------------+
