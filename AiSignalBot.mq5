//+------------------------------------------------------------------+
//|                                                 AiSignalBot.mq5   |
//|                                                                    |
//| Ask-before-you-trade bot for MetaTrader 5, powered by a real      |
//| trained ML model instead of fixed indicator rules.                |
//|                                                                    |
//| For each scanned symbol, sends recent price bars to a small AI    |
//| service (ai_service/app.py, meant to run on the same VPS) over    |
//| HTTP and gets back a direction + confidence. When confident        |
//| enough, shows a panel on the chart with the symbol, the call       |
//| (BUY / SELL), and Yes/No buttons. Nothing is ever sent to your     |
//| broker until you click YES.                                       |
//+------------------------------------------------------------------+
#property copyright "AiSignalBot"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>

//--------------------------------------------------------------------
// Inputs
//--------------------------------------------------------------------
input string          InpSymbols                   = "BTC,ETH,XRP,EURUSD,GBPUSD,USDCHF,USDJPY"; // Symbols to scan, comma-separated (empty = all Market Watch symbols). XAGUSD is M1-only, runs on a separate instance - don't add it here. XAUUSD/EURGBP/ZEC/XAUAUD/BNB removed - no significant edge survives proper validation.
input int             InpMaxSymbolsToScan          = 30;       // Safety cap on number of symbols scanned
input ENUM_TIMEFRAMES InpTimeframe                 = PERIOD_M15; // Timeframe used for signals
input string          InpAiServiceUrl              = "http://127.0.0.1:8787/predict"; // AI service endpoint (must be whitelisted in Options > Expert Advisors) - set to your Koyeb URL + /predict if hosted there
input string          InpAiApiKey                  = "";       // Must match the API_KEY set on the AI service, once it's on the public internet (e.g. Koyeb)
input bool            InpRemoteApprovalEnabled     = true;     // Let the Telegram bot approve/deny proposals too, alongside the desktop chart buttons
input int             InpAiBarsToSend              = 120;      // How many recent bars to send the AI service each query
input int             InpAtrPeriod                 = 14;       // ATR period (used for stop-loss/take-profit distance)
input double          InpSLATRMult                 = 1.5;      // Stop-loss distance = ATR * this
input double          InpTPATRMult                 = 3.0;      // Take-profit distance = ATR * this
input bool            InpTrailingEnabled           = true;     // Trail the stop-loss on open bot positions as they move favorably
input double          InpTrailingStartATR          = 1.0;      // Start trailing once profit reaches this many ATR
input double          InpTrailingDistanceATR       = 1.5;      // Trailing stop stays this many ATR behind price once active
input double          InpRiskPercent               = 0.1;      // Target risk per trade, % of balance
input double          InpDailyLossLimitPercent     = 3.0;      // Stop proposing trades after this % daily equity loss
input int             InpMagicNumber               = 990022;   // Magic number for this bot's orders
input int             InpMaxOpenTrades             = 1;        // Max simultaneous open trades from this bot
input int             InpScanIntervalSeconds       = 30;       // How often to scan for new signals
input int             InpProposalTimeoutSeconds    = 120;      // Auto-dismiss an unanswered proposal after this long
input bool            InpConfirmLiveRiskUnderstood = false;    // Set to TRUE to allow the bot to actually send live orders
input bool            InpEnablePushNotifications   = true;     // Push each proposal/fill/halt to your phone via MT5 mobile

//--------------------------------------------------------------------
// Symbol tracking (only need an ATR handle now - direction comes from the AI service)
//--------------------------------------------------------------------
struct SymState
  {
   string   symbol;
   int      hATR;
   datetime lastHandledBar;
  };

SymState g_syms[];

//--------------------------------------------------------------------
// Pending proposal (only one at a time, kept simple on purpose)
//--------------------------------------------------------------------
bool     g_pendingActive      = false;
string   g_pendSymbol         = "";
int      g_pendDirection      = 0;      // 1 = BUY, -1 = SELL
double   g_pendLots           = 0;
double   g_pendEntryApprox    = 0;
double   g_pendSLDistance     = 0;
double   g_pendTPDistance     = 0;
double   g_pendRiskMoney      = 0;
double   g_pendRiskPercentAct = 0;
double   g_pendConfidence     = 0;
datetime g_pendBarTime        = 0;
datetime g_pendCreatedAt      = 0;
string   g_pendRemoteId       = "";     // id of this proposal on the Telegram approval service, if registered

//--------------------------------------------------------------------
// Daily loss tracking
//--------------------------------------------------------------------
double   g_dayStartBalance = 0;
int      g_dayOfYear       = -1;
bool     g_haltedForDay    = false;

CTrade   trade;

#define OBJ_PREFIX "AISB_"

//+------------------------------------------------------------------+
void SendPush(string msg)
  {
   if(!InpEnablePushNotifications)
      return;
   if(StringLen(msg) > 250)
      msg = StringSubstr(msg, 0, 250);
   if(!SendNotification(msg))
      Print("Push notification not sent (set up MetaQuotes ID under Tools > Options > Notifications). Message was: ", msg);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);

   BuildSymbolList();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayOfYear = dt.day_of_year;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_haltedForDay = false;

   EventSetTimer(MathMax(5, InpScanIntervalSeconds));

   PrintFormat("AiSignalBot started. Scanning %d symbol(s) on %s via %s.",
               ArraySize(g_syms), EnumToString(InpTimeframe), InpAiServiceUrl);
   if(!InpConfirmLiveRiskUnderstood)
      Print("NOTE: InpConfirmLiveRiskUnderstood is FALSE. Proposals will show but no live orders will be sent.");

   UpdateStatusComment();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++)
      if(g_syms[i].hATR != INVALID_HANDLE)
         IndicatorRelease(g_syms[i].hATR);
   RemoveProposalPanel();
   Comment("");
  }

//+------------------------------------------------------------------+
void BuildSymbolList()
  {
   ArrayFree(g_syms);
   string list[];
   int count = 0;

   if(StringLen(InpSymbols) > 0)
     {
      count = StringSplit(InpSymbols, ',', list);
     }
   else
     {
      int total = SymbolsTotal(true);
      ArrayResize(list, total);
      count = total;
      for(int i = 0; i < total; i++)
         list[i] = SymbolName(i, true);
     }

   int added = 0;
   for(int i = 0; i < count && added < InpMaxSymbolsToScan; i++)
     {
      string sym = list[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(StringLen(sym) == 0)
         continue;
      if(!SymbolSelect(sym, true))
         continue;
      long tradeMode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
      if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
         continue;

      int hATR = iATR(sym, InpTimeframe, InpAtrPeriod);
      if(hATR == INVALID_HANDLE)
        {
         PrintFormat("Skipping %s: could not create ATR handle.", sym);
         continue;
        }

      int n = ArraySize(g_syms);
      ArrayResize(g_syms, n + 1);
      g_syms[n].symbol         = sym;
      g_syms[n].hATR           = hATR;
      g_syms[n].lastHandledBar = 0;
      added++;
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckDailyReset();
   ManageTrailingStops(); // protect open positions regardless of halt/pending state

   if(g_haltedForDay)
     {
      UpdateStatusComment();
      return;
     }

   if(g_pendingActive)
     {
      string remoteDecision = PollRemoteDecision();
      if(remoteDecision == "yes")
        {
         Print("Proposal for ", g_pendSymbol, " approved from the phone panel.");
         HandleYes();
        }
      else if(remoteDecision == "no")
        {
         Print("Proposal for ", g_pendSymbol, " declined from the phone panel.");
         HandleNo();
        }
     }

   if(g_pendingActive && (TimeCurrent() - g_pendCreatedAt) > InpProposalTimeoutSeconds)
     {
      Print("Proposal for ", g_pendSymbol, " timed out with no response - dismissed.");
      RemoveProposalPanel();
      ClearRemoteProposal();
      g_pendingActive = false;
     }

   if(g_pendingActive)
     {
      UpdateStatusComment();
      return;
     }

   if(CountOpenBotTrades() >= InpMaxOpenTrades)
     {
      UpdateStatusComment();
      return;
     }

   ScanForSignal();
   UpdateStatusComment();
  }

//+------------------------------------------------------------------+
void CheckDailyReset()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayOfYear)
     {
      g_dayOfYear = dt.day_of_year;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_haltedForDay = false;
      Print("New trading day. Daily loss limit reset. Day-start balance = ", DoubleToString(g_dayStartBalance, 2));
      return;
     }

   if(g_dayStartBalance <= 0)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   if(!g_haltedForDay && lossPct >= InpDailyLossLimitPercent)
     {
      g_haltedForDay = true;
      RemoveProposalPanel();
      g_pendingActive = false;
      PrintFormat("Daily loss limit hit (%.2f%% >= %.2f%%). No new trades will be proposed until tomorrow.",
                  lossPct, InpDailyLossLimitPercent);
      SendPush(StringFormat("HALTED: daily loss limit hit (%.1f%%). No new trades until tomorrow.", lossPct));
     }
  }

//+------------------------------------------------------------------+
int CountOpenBotTrades()
  {
   int cnt = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         cnt++;
     }
   return cnt;
  }

bool HasOpenBotTrade(string symbol)
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
double GetCurrentATR(string symbol)
  {
   int h = iATR(symbol, InpTimeframe, InpAtrPeriod);
   if(h == INVALID_HANDLE)
      return 0;
   double buf[];
   double result = 0;
   if(CopyBuffer(h, 0, 1, 1, buf) >= 1)
      result = buf[0];
   IndicatorRelease(h);
   return result;
  }

//+------------------------------------------------------------------+
// Trail the SL behind price once a bot position is far enough in     |
// profit (InpTrailingStartATR * ATR), keeping InpTrailingDistanceATR |
// ATR of breathing room. Only ever tightens the stop, never loosens  |
// it, and never touches the take-profit.                             |
//+------------------------------------------------------------------+
void ManageTrailingStops()
  {
   if(!InpTrailingEnabled)
      return;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      string symbol   = PositionGetString(POSITION_SYMBOL);
      long   posType  = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double atr = GetCurrentATR(symbol);
      if(atr <= 0)
         continue;

      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double minStopDistance = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

      if(posType == POSITION_TYPE_BUY)
        {
         double price = SymbolInfoDouble(symbol, SYMBOL_BID);
         double profitDist = price - openPrice;
         if(profitDist < InpTrailingStartATR * atr)
            continue;

         double desiredSL = NormalizeDouble(price - InpTrailingDistanceATR * atr, digits);
         if(currentSL != 0 && desiredSL <= currentSL)
            continue; // would loosen or no real change
         if(price - desiredSL < minStopDistance)
            continue; // too close to price for this broker to accept

         if(trade.PositionModify(symbol, desiredSL, currentTP))
            PrintFormat("Trailing stop updated for %s: SL -> %s", symbol, DoubleToString(desiredSL, digits));
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double profitDist = openPrice - price;
         if(profitDist < InpTrailingStartATR * atr)
            continue;

         double desiredSL = NormalizeDouble(price + InpTrailingDistanceATR * atr, digits);
         if(currentSL != 0 && desiredSL >= currentSL)
            continue;
         if(desiredSL - price < minStopDistance)
            continue;

         if(trade.PositionModify(symbol, desiredSL, currentTP))
            PrintFormat("Trailing stop updated for %s: SL -> %s", symbol, DoubleToString(desiredSL, digits));
        }
     }
  }

//+------------------------------------------------------------------+
// Build a JSON array literal from a double array, e.g. [1.23,1.24,...] |
//+------------------------------------------------------------------+
string DoubleArrayToJson(double &arr[], int count, int digits)
  {
   string s = "[";
   for(int i = 0; i < count; i++)
     {
      if(i > 0) s += ",";
      s += DoubleToString(arr[i], digits);
     }
   s += "]";
   return s;
  }

//+------------------------------------------------------------------+
// Minimal JSON value extractor for the fixed, self-controlled schema |
// the AI service returns - not a general JSON parser.                |
//+------------------------------------------------------------------+
string ExtractJsonValue(string json, string key)
  {
   string pattern = "\"" + key + "\"";
   int pos = StringFind(json, pattern);
   if(pos < 0) return "";
   pos = StringFind(json, ":", pos);
   if(pos < 0) return "";
   pos++;
   int len = StringLen(json);
   while(pos < len && StringGetCharacter(json, pos) == ' ')
      pos++;
   if(pos >= len) return "";

   if(StringGetCharacter(json, pos) == '"')
     {
      pos++;
      int endPos = StringFind(json, "\"", pos);
      if(endPos < 0) return "";
      return StringSubstr(json, pos, endPos - pos);
     }

   int endPos = pos;
   while(endPos < len)
     {
      ushort c = StringGetCharacter(json, endPos);
      if(c == ',' || c == '}')
         break;
      endPos++;
     }
   return StringSubstr(json, pos, endPos - pos);
  }

//+------------------------------------------------------------------+
// Remote approval: the AI service also holds a single pending proposal |
// that a Telegram bot can answer with real Approve/Deny buttons.       |
// Whichever of the desktop chart or Telegram answers first wins; the  |
// EA notifies the service of a desktop answer, and polls it for a     |
// Telegram answer.                                                     |
//+------------------------------------------------------------------+
string GetServiceBaseUrl()
  {
   string url = InpAiServiceUrl;
   int pos = StringFind(url, "/predict");
   if(pos >= 0)
      return StringSubstr(url, 0, pos);
   return url;
  }

string BuildServiceUrl(string path)
  {
   string url = GetServiceBaseUrl() + path;
   if(StringLen(InpAiApiKey) > 0)
      url += "?key=" + InpAiApiKey;
   return url;
  }

bool HttpGetJson(string url, string &outBody)
  {
   uchar postData[];
   uchar result[];
   string resultHeaders;
   ResetLastError();
   int status = WebRequest("GET", url, "", 30000, postData, result, resultHeaders);
   if(status != 200)
      return false;
   outBody = CharArrayToString(result);
   return true;
  }

bool HttpPostJson(string url, string body, string &outBody)
  {
   uchar postData[];
   int rawLen = StringToCharArray(body, postData);
   ArrayResize(postData, rawLen - 1);
   uchar result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   ResetLastError();
   int status = WebRequest("POST", url, headers, 30000, postData, result, resultHeaders);
   if(status != 200)
      return false;
   outBody = CharArrayToString(result);
   return true;
  }

void RegisterRemoteProposal(string symbol, string direction, double confidence, double lots,
                             double riskMoney, double riskPct, double entryApprox, int digits)
  {
   g_pendRemoteId = "";
   if(!InpRemoteApprovalEnabled)
      return;

   string body = StringFormat(
      "{\"symbol\":\"%s\",\"direction\":\"%s\",\"confidence\":%s,\"lots\":\"%s\",\"risk_money\":%s,\"risk_pct\":%s,\"entry_approx\":\"%s\"}",
      symbol, direction, DoubleToString(confidence, 4), DoubleToString(lots, 2),
      DoubleToString(riskMoney, 2), DoubleToString(riskPct, 2), DoubleToString(entryApprox, digits));

   string resp;
   if(!HttpPostJson(BuildServiceUrl("/propose"), body, resp))
     {
      Print("Remote approval: could not register proposal with the phone panel - desktop Yes/No still works.");
      return;
     }
   g_pendRemoteId = ExtractJsonValue(resp, "id");
  }

// Returns "yes"/"no" once the phone has answered this exact proposal, else "".
string PollRemoteDecision()
  {
   if(!InpRemoteApprovalEnabled || g_pendRemoteId == "")
      return "";

   string resp;
   if(!HttpGetJson(BuildServiceUrl("/proposal"), resp))
      return "";

   if(ExtractJsonValue(resp, "id") != g_pendRemoteId)
      return "";

   string decision = ExtractJsonValue(resp, "decision");
   if(decision == "yes" || decision == "no")
      return decision;
   return "";
  }

// Tell the phone panel a decision was made on the desktop, so it updates too.
void PostRemoteDecision(string decision)
  {
   if(!InpRemoteApprovalEnabled || g_pendRemoteId == "")
      return;
   string body = StringFormat("{\"id\":\"%s\",\"decision\":\"%s\",\"decided_by\":\"desktop\"}", g_pendRemoteId, decision);
   string resp;
   HttpPostJson(BuildServiceUrl("/proposal/decide"), body, resp);
  }

void ClearRemoteProposal()
  {
   if(g_pendRemoteId == "")
      return;
   string body = StringFormat("{\"id\":\"%s\"}", g_pendRemoteId);
   string resp;
   HttpPostJson(BuildServiceUrl("/proposal/clear"), body, resp);
   g_pendRemoteId = "";
  }

//+------------------------------------------------------------------+
// Query the AI service for one symbol's latest direction/confidence. |
//+------------------------------------------------------------------+
bool QueryAiService(string symbol, string &outDirection, double &outConfidence)
  {
   outDirection = "none";
   outConfidence = 0;

   MqlRates rates[];
   int copied = CopyRates(symbol, InpTimeframe, 1, InpAiBarsToSend, rates); // shift 1: skip the still-forming bar
   if(copied < 40)
      return false;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   double closes[], highs[], lows[];
   ArrayResize(closes, copied);
   ArrayResize(highs, copied);
   ArrayResize(lows, copied);
   string timesJson = "[";
   for(int i = 0; i < copied; i++)
     {
      closes[i] = rates[i].close;
      highs[i]  = rates[i].high;
      lows[i]   = rates[i].low;
      if(i > 0) timesJson += ",";
      timesJson += IntegerToString((int)rates[i].time);
     }
   timesJson += "]";

   string body = StringFormat("{\"symbol\":\"%s\",\"times\":%s,\"closes\":%s,\"highs\":%s,\"lows\":%s}",
                               symbol, timesJson,
                               DoubleArrayToJson(closes, copied, digits),
                               DoubleArrayToJson(highs, copied, digits),
                               DoubleArrayToJson(lows, copied, digits));

   uchar postData[];
   int rawLen = StringToCharArray(body, postData); // copies whole string plus a trailing zero
   ArrayResize(postData, rawLen - 1);              // drop that trailing zero before sending

   string headers = "Content-Type: application/json\r\n";
   if(StringLen(InpAiApiKey) > 0)
      headers += "X-API-Key: " + InpAiApiKey + "\r\n";
   uchar result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", InpAiServiceUrl, headers, 60000, postData, result, resultHeaders);
   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
         PrintFormat("WebRequest blocked - add %s under Tools > Options > Expert Advisors > Allow WebRequest for listed URL.", InpAiServiceUrl);
      else
         PrintFormat("WebRequest to AI service failed for %s, error %d", symbol, err);
      return false;
     }
   if(status != 200)
     {
      PrintFormat("AI service returned HTTP %d for %s", status, symbol);
      return false;
     }

   string response = CharArrayToString(result);
   string dir = ExtractJsonValue(response, "direction");
   if(dir == "")
     {
      PrintFormat("AI service returned an unparseable response for %s: %s", symbol, response);
      return false;
     }

   outDirection = dir;
   outConfidence = StringToDouble(ExtractJsonValue(response, "confidence"));
   return true;
  }

//+------------------------------------------------------------------+
double CalcLots(string symbol, double slDistPrice, double riskPercent, double &outRiskMoney, double &outActualRiskPct)
  {
   outRiskMoney = 0;
   outActualRiskPct = 0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0 || slDistPrice <= 0)
      return 0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return 0;

   double moneyPerLotAtSL = (slDistPrice / tickSize) * tickValue;
   if(moneyPerLotAtSL <= 0)
      return 0;

   double targetRiskMoney = balance * riskPercent / 100.0;
   double lots = targetRiskMoney / moneyPerLotAtSL;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = minLot > 0 ? minLot : 0.01;

   double normalized = MathFloor(lots / step + 0.0000001) * step;
   if(normalized < minLot)
      normalized = minLot;
   if(maxLot > 0 && normalized > maxLot)
      normalized = maxLot;
   if(normalized <= 0)
      return 0;

   double actualRiskMoney = normalized * moneyPerLotAtSL;
   outRiskMoney = actualRiskMoney;
   outActualRiskPct = (balance > 0) ? (actualRiskMoney / balance * 100.0) : 0;

   return normalized;
  }

//+------------------------------------------------------------------+
void ScanForSignal()
  {
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      string sym = g_syms[i].symbol;

      if(HasOpenBotTrade(sym))
         continue;

      datetime barTime[];
      if(CopyTime(sym, InpTimeframe, 0, 3, barTime) < 3)
         continue;
      datetime lastClosedBarTime = barTime[1];

      if(g_syms[i].lastHandledBar == lastClosedBarTime)
         continue; // already asked the AI about this bar for this symbol

      g_syms[i].lastHandledBar = lastClosedBarTime; // mark handled regardless of outcome

      string direction;
      double confidence;
      if(!QueryAiService(sym, direction, confidence))
         continue;

      int dirCode = 0;
      if(direction == "buy") dirCode = 1;
      else if(direction == "sell") dirCode = -1;
      if(dirCode == 0)
         continue; // AI said "none" - no edge confident enough right now

      double atr[];
      if(CopyBuffer(g_syms[i].hATR, 0, 1, 1, atr) < 1)
         continue;
      double atrValue = atr[0];
      if(atrValue <= 0)
         continue;

      double slDist = atrValue * InpSLATRMult;
      double tpDist = atrValue * InpTPATRMult;

      double riskMoney, actualRiskPct, lots;
      lots = CalcLots(sym, slDist, InpRiskPercent, riskMoney, actualRiskPct);
      if(lots <= 0)
         continue;

      double price = (dirCode == 1) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);

      g_pendingActive      = true;
      g_pendSymbol         = sym;
      g_pendDirection      = dirCode;
      g_pendLots           = lots;
      g_pendEntryApprox    = price;
      g_pendSLDistance     = slDist;
      g_pendTPDistance     = tpDist;
      g_pendRiskMoney      = riskMoney;
      g_pendRiskPercentAct = actualRiskPct;
      g_pendConfidence     = confidence;
      g_pendBarTime        = lastClosedBarTime;
      g_pendCreatedAt      = TimeCurrent();

      ShowProposalPanel();

      int symDigits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      RegisterRemoteProposal(sym, (dirCode == 1 ? "buy" : "sell"), confidence, lots,
                              riskMoney, actualRiskPct, price, symDigits);

      string dirWord = (dirCode == 1) ? "BUY" : "SELL";
      SendPush(StringFormat("%s %s (%.0f%% conf)  lots %s  risk $%.2f (%.1f%%)  entry ~%s",
                             sym, dirWord, confidence * 100.0, DoubleToString(lots, 2), riskMoney, actualRiskPct,
                             DoubleToString(price, symDigits)));

      return; // only propose one signal per scan
     }
  }

//+------------------------------------------------------------------+
void ShowProposalPanel()
  {
   RemoveProposalPanel();

   int x = 20, y = 40, w = 250;
   color bg = C'30,30,30';
   color dirColor = (g_pendDirection == 1) ? clrLimeGreen : clrCrimson;
   string dirWord = (g_pendDirection == 1) ? "BUY" : "SELL";

   CreateRectLabel(OBJ_PREFIX "bg", x, y, w, 170, bg);
   CreateLabel(OBJ_PREFIX "title", x + 10, y + 8, g_pendSymbol, clrWhite, 11);
   CreateLabel(OBJ_PREFIX "dir", x + 10, y + 28, dirWord, dirColor, 20);
   CreateLabel(OBJ_PREFIX "conf", x + 120, y + 34, StringFormat("%.0f%% confidence", g_pendConfidence * 100.0), clrAqua, 9);

   string details = StringFormat("Lots: %s   Risk: $%.2f (%.2f%%)",
                                  DoubleToString(g_pendLots, 2), g_pendRiskMoney, g_pendRiskPercentAct);
   CreateLabel(OBJ_PREFIX "details", x + 10, y + 62, details, clrSilver, 9);

   if(g_pendRiskPercentAct > InpRiskPercent * 1.5)
      CreateLabel(OBJ_PREFIX "warn", x + 10, y + 80, "Min lot forces higher risk than target!", clrOrange, 8);

   CreateLabel(OBJ_PREFIX "note", x + 10, y + 100, "AI model output - not a guarantee.", clrGray, 8);

   CreateButton(OBJ_PREFIX "yes", x + 10,  y + 125, 105, 32, "YES", clrDarkGreen);
   CreateButton(OBJ_PREFIX "no",  x + 130, y + 125, 105, 32, "NO",  clrMaroon);

   ChartRedraw();
  }

void RemoveProposalPanel()
  {
   ObjectDelete(0, OBJ_PREFIX "bg");
   ObjectDelete(0, OBJ_PREFIX "title");
   ObjectDelete(0, OBJ_PREFIX "dir");
   ObjectDelete(0, OBJ_PREFIX "conf");
   ObjectDelete(0, OBJ_PREFIX "details");
   ObjectDelete(0, OBJ_PREFIX "warn");
   ObjectDelete(0, OBJ_PREFIX "note");
   ObjectDelete(0, OBJ_PREFIX "yes");
   ObjectDelete(0, OBJ_PREFIX "no");
   ChartRedraw();
  }

void CreateRectLabel(string name, int x, int y, int w, int h, color clr)
  {
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void CreateLabel(string name, int x, int y, string text, color clr, int fontSize)
  {
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void CreateButton(string name, int x, int y, int w, int h, string text, color clr)
  {
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 11);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == OBJ_PREFIX "yes")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      HandleYes();
     }
   else if(sparam == OBJ_PREFIX "no")
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      HandleNo();
     }
  }

//+------------------------------------------------------------------+
void HandleNo()
  {
   Print("Proposal declined by user: ", g_pendSymbol, " ", (g_pendDirection == 1 ? "BUY" : "SELL"));
   PostRemoteDecision("no"); // no-op if this came from the phone already, or remote approval is off
   ClearRemoteProposal();
   RemoveProposalPanel();
   g_pendingActive = false;
  }

//+------------------------------------------------------------------+
void HandleYes()
  {
   string sym = g_pendSymbol;
   int dir = g_pendDirection;
   double lots = g_pendLots;

   PostRemoteDecision("yes"); // no-op if this came from the phone already, or remote approval is off
   ClearRemoteProposal();
   RemoveProposalPanel();
   g_pendingActive = false;

   if(!InpConfirmLiveRiskUnderstood)
     {
      Alert("Set InpConfirmLiveRiskUnderstood = true in the EA inputs to allow live orders.");
      Print("Order NOT sent - InpConfirmLiveRiskUnderstood is false.");
      return;
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Alert("AlgoTrading is not enabled in the terminal. Enable the 'Algo Trading' button and try again.");
      return;
     }

   if(HasOpenBotTrade(sym))
     {
      Print("Skipped: already have an open bot trade on ", sym);
      return;
     }

   double price = (dir == 1) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double sl, tp;
   if(dir == 1)
     {
      sl = price - g_pendSLDistance;
      tp = price + g_pendTPDistance;
     }
   else
     {
      sl = price + g_pendSLDistance;
      tp = price - g_pendTPDistance;
     }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool ok;
   string comment = "AiSignalBot";
   if(dir == 1)
      ok = trade.Buy(lots, sym, price, sl, tp, comment);
   else
      ok = trade.Sell(lots, sym, price, sl, tp, comment);

   if(ok)
     {
      PrintFormat("Order sent: %s %s lots=%s SL=%s TP=%s", sym, (dir == 1 ? "BUY" : "SELL"),
                  DoubleToString(lots, 2), DoubleToString(sl, digits), DoubleToString(tp, digits));
      SendPush(StringFormat("FILLED: %s %s %s lots @ %s", sym, (dir == 1 ? "BUY" : "SELL"),
                             DoubleToString(lots, 2), DoubleToString(price, digits)));
     }
   else
     {
      PrintFormat("Order FAILED for %s: retcode=%d desc=%s", sym, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      SendPush(StringFormat("Order FAILED for %s: %s", sym, trade.ResultRetcodeDescription()));
     }
  }

//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   string status;
   if(g_haltedForDay)
      status = "HALTED - daily loss limit reached. Resumes next trading day.";
   else if(g_pendingActive)
      status = "Waiting for your YES/NO on " + g_pendSymbol + "...";
   else
      status = StringFormat("Asking AI service about %d symbol(s) every %ds. Open bot trades: %d/%d.",
                             ArraySize(g_syms), InpScanIntervalSeconds, CountOpenBotTrades(), InpMaxOpenTrades);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   string liveFlag = InpConfirmLiveRiskUnderstood ? "LIVE ORDERS ENABLED" : "LIVE ORDERS DISABLED (proposals only)";

   Comment(StringFormat("AiSignalBot\n%s\nBalance: %.2f  Equity: %.2f\n%s\nAI: %s",
                         status, balance, equity, liveFlag, InpAiServiceUrl));
  }
//+------------------------------------------------------------------+
