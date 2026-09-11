//+------------------------------------------------------------------+
//|                                              TrendSignalBot.mq5   |
//|                                                                    |
//| Simple ask-before-you-trade bot for MetaTrader 5.                 |
//|                                                                    |
//| Scans the symbols in your Market Watch for a basic trend/momentum |
//| signal (EMA crossover confirmed by RSI). When it finds one, it    |
//| shows a small panel on the chart with the symbol, a one-word      |
//| call (BUY / SELL), and Yes/No buttons. Nothing is ever sent to    |
//| your broker until you click YES.                                  |
//+------------------------------------------------------------------+
#property copyright "TrendSignalBot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--------------------------------------------------------------------
// Inputs
//--------------------------------------------------------------------
input string          InpSymbols                   = "";      // Symbols to scan, comma-separated (empty = all Market Watch symbols)
input int             InpMaxSymbolsToScan          = 30;       // Safety cap on number of symbols scanned
input ENUM_TIMEFRAMES InpTimeframe                 = PERIOD_M15; // Timeframe used for signals
input int             InpFastEMA                   = 12;       // Fast EMA period
input int             InpSlowEMA                   = 26;       // Slow EMA period
input int             InpRSIPeriod                 = 14;       // RSI period
input double          InpRSIBuyLevel               = 55.0;     // RSI must be above this for a BUY
input double          InpRSISellLevel              = 45.0;     // RSI must be below this for a SELL
input int             InpATRPeriod                 = 14;       // ATR period (used for stop-loss/take-profit distance)
input double          InpSLATRMult                 = 1.5;      // Stop-loss distance = ATR * this
input double          InpTPATRMult                 = 3.0;      // Take-profit distance = ATR * this
input double          InpRiskPercent               = 0.1;      // Target risk per trade, % of balance
input double          InpDailyLossLimitPercent     = 3.0;      // Stop proposing trades after this % daily equity loss
input int             InpMagicNumber               = 990011;   // Magic number for this bot's orders
input int             InpMaxOpenTrades             = 1;        // Max simultaneous open trades from this bot
input int             InpScanIntervalSeconds       = 30;       // How often to scan for new signals
input int             InpProposalTimeoutSeconds    = 120;      // Auto-dismiss an unanswered proposal after this long
input bool            InpConfirmLiveRiskUnderstood = false;    // Set to TRUE to allow the bot to actually send live orders
input bool            InpEnablePushNotifications   = true;     // Push each proposal/fill/halt to your phone via MT5 mobile (Options > Notifications)

//--------------------------------------------------------------------
// Symbol tracking
//--------------------------------------------------------------------
struct SymState
  {
   string   symbol;
   int      hFastEMA;
   int      hSlowEMA;
   int      hRSI;
   int      hATR;
   datetime lastHandledBar; // last bar time we already showed a proposal for (accepted, declined, or skipped)
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
double   g_pendSLDistance     = 0;      // price distance, recomputed at click time
double   g_pendTPDistance     = 0;
double   g_pendRiskMoney      = 0;
double   g_pendRiskPercentAct = 0;
datetime g_pendBarTime        = 0;
datetime g_pendCreatedAt      = 0;

//--------------------------------------------------------------------
// Daily loss tracking
//--------------------------------------------------------------------
double   g_dayStartBalance = 0;
int      g_dayOfYear       = -1;
bool     g_haltedForDay    = false;

CTrade   trade;

#define OBJ_PREFIX "TSB_"

//+------------------------------------------------------------------+
// Push a short message to the MT5 mobile app on your phone (if you've|
// linked it under Tools > Options > Notifications in the terminal). |
// Silently no-ops (just logs) if push isn't set up - never blocks   |
// trading logic.                                                    |
//+------------------------------------------------------------------+
void SendPush(string msg)
  {
   if(!InpEnablePushNotifications)
      return;
   if(StringLen(msg) > 250)
      msg = StringSubstr(msg, 0, 250);
   if(!SendNotification(msg))
      Print("Push notification not sent (set up MetaQuotes ID under Tools > Options > Notifications to enable). Message was: ", msg);
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

   PrintFormat("TrendSignalBot started. Scanning %d symbol(s) on %s.", ArraySize(g_syms), EnumToString(InpTimeframe));
   if(!InpConfirmLiveRiskUnderstood)
      Print("NOTE: InpConfirmLiveRiskUnderstood is FALSE. The bot will show trade proposals but will NOT send any live orders until you set this input to TRUE.");

   UpdateStatusComment();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      if(g_syms[i].hFastEMA != INVALID_HANDLE) IndicatorRelease(g_syms[i].hFastEMA);
      if(g_syms[i].hSlowEMA != INVALID_HANDLE) IndicatorRelease(g_syms[i].hSlowEMA);
      if(g_syms[i].hRSI     != INVALID_HANDLE) IndicatorRelease(g_syms[i].hRSI);
      if(g_syms[i].hATR     != INVALID_HANDLE) IndicatorRelease(g_syms[i].hATR);
     }
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
      int total = SymbolsTotal(true); // symbols currently in Market Watch
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

      int hFast = iMA(sym, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      int hSlow = iMA(sym, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      int hRSI  = iRSI(sym, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
      int hATR  = iATR(sym, InpTimeframe, InpATRPeriod);
      if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
        {
         PrintFormat("Skipping %s: could not create indicator handles.", sym);
         continue;
        }

      int n = ArraySize(g_syms);
      ArrayResize(g_syms, n + 1);
      g_syms[n].symbol         = sym;
      g_syms[n].hFastEMA       = hFast;
      g_syms[n].hSlowEMA       = hSlow;
      g_syms[n].hRSI           = hRSI;
      g_syms[n].hATR           = hATR;
      g_syms[n].lastHandledBar = 0;
      added++;
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckDailyReset();

   if(g_haltedForDay)
     {
      UpdateStatusComment();
      return;
     }

   // Auto-dismiss a stale proposal so the bot doesn't get stuck forever
   if(g_pendingActive && (TimeCurrent() - g_pendCreatedAt) > InpProposalTimeoutSeconds)
     {
      Print("Proposal for ", g_pendSymbol, " timed out with no response - dismissed.");
      RemoveProposalPanel();
      g_pendingActive = false;
     }

   if(g_pendingActive)
     {
      UpdateStatusComment();
      return; // one proposal at a time
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
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         cnt++;
     }
   return cnt;
  }

bool HasOpenBotTrade(string symbol)
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == symbol)
         return true;
     }
   return false;
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
      datetime lastClosedBarTime = barTime[1]; // index 0 = current forming bar

      if(g_syms[i].lastHandledBar == lastClosedBarTime)
         continue; // already handled this bar for this symbol

      double fast[], slow[], rsi[], atr[];
      if(CopyBuffer(g_syms[i].hFastEMA, 0, 1, 2, fast) < 2) continue;
      if(CopyBuffer(g_syms[i].hSlowEMA, 0, 1, 2, slow) < 2) continue;
      if(CopyBuffer(g_syms[i].hRSI,     0, 1, 1, rsi)  < 1) continue;
      if(CopyBuffer(g_syms[i].hATR,     0, 1, 1, atr)  < 1) continue;

      // CopyBuffer(handle, 0, 1, 2, ...) returns a timeseries-ordered array:
      // index 0 = last closed bar (shift 1), index 1 = the bar before that (shift 2)
      bool crossedUp   = (fast[1] <= slow[1]) && (fast[0] > slow[0]);
      bool crossedDown = (fast[1] >= slow[1]) && (fast[0] < slow[0]);

      int direction = 0;
      if(crossedUp && rsi[0] > InpRSIBuyLevel)
         direction = 1;
      else if(crossedDown && rsi[0] < InpRSISellLevel)
         direction = -1;

      g_syms[i].lastHandledBar = lastClosedBarTime; // mark handled regardless, so we don't re-check this bar

      if(direction == 0)
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

      double price = (direction == 1) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);

      g_pendingActive      = true;
      g_pendSymbol         = sym;
      g_pendDirection      = direction;
      g_pendLots           = lots;
      g_pendEntryApprox    = price;
      g_pendSLDistance     = slDist;
      g_pendTPDistance     = tpDist;
      g_pendRiskMoney      = riskMoney;
      g_pendRiskPercentAct = actualRiskPct;
      g_pendBarTime        = lastClosedBarTime;
      g_pendCreatedAt      = TimeCurrent();

      ShowProposalPanel();

      string dirWord = (direction == 1) ? "BUY" : "SELL";
      SendPush(StringFormat("%s %s  lots %s  risk $%.2f (%.1f%%)  entry ~%s",
                             sym, dirWord, DoubleToString(lots, 2), riskMoney, actualRiskPct,
                             DoubleToString(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS))));

      return; // only propose one signal per scan
     }
  }

//+------------------------------------------------------------------+
// Position sizing: target InpRiskPercent of balance, respecting the  |
// broker's minimum lot. With a very small account the minimum lot   |
// can force real risk above the target - actualRiskPct reports that |
// so the trader can see it before approving.                        |
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

   double moneyPerLotAtSL = (slDistPrice / tickSize) * tickValue; // $ risk for 1.0 lot at this SL distance
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
      normalized = minLot; // can't go smaller than the broker allows
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
// On-chart proposal panel with YES / NO buttons                     |
//+------------------------------------------------------------------+
void ShowProposalPanel()
  {
   RemoveProposalPanel();

   int x = 20, y = 40, w = 230;
   color bg = C'30,30,30';
   color dirColor = (g_pendDirection == 1) ? clrLimeGreen : clrCrimson;
   string dirWord = (g_pendDirection == 1) ? "BUY" : "SELL";

   CreateRectLabel(OBJ_PREFIX "bg", x, y, w, 150, bg);
   CreateLabel(OBJ_PREFIX "title", x + 10, y + 8, g_pendSymbol, clrWhite, 11);
   CreateLabel(OBJ_PREFIX "dir", x + 10, y + 28, dirWord, dirColor, 20);

   string details = StringFormat("Lots: %s   Risk: $%.2f (%.2f%%)",
                                  DoubleToString(g_pendLots, 2), g_pendRiskMoney, g_pendRiskPercentAct);
   CreateLabel(OBJ_PREFIX "details", x + 10, y + 62, details, clrSilver, 9);

   if(g_pendRiskPercentAct > InpRiskPercent * 1.5)
     {
      CreateLabel(OBJ_PREFIX "warn", x + 10, y + 80, "Min lot forces higher risk than target!", clrOrange, 8);
     }

   CreateButton(OBJ_PREFIX "yes", x + 10,  y + 105, 95, 32, "YES", clrDarkGreen);
   CreateButton(OBJ_PREFIX "no",  x + 120, y + 105, 95, 32, "NO",  clrMaroon);

   ChartRedraw();
  }

void RemoveProposalPanel()
  {
   ObjectDelete(0, OBJ_PREFIX "bg");
   ObjectDelete(0, OBJ_PREFIX "title");
   ObjectDelete(0, OBJ_PREFIX "dir");
   ObjectDelete(0, OBJ_PREFIX "details");
   ObjectDelete(0, OBJ_PREFIX "warn");
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
   RemoveProposalPanel();
   g_pendingActive = false;
  }

//+------------------------------------------------------------------+
void HandleYes()
  {
   string sym = g_pendSymbol;
   int dir = g_pendDirection;
   double lots = g_pendLots;

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
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
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
   string comment = "TrendSignalBot";
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
      status = StringFormat("Scanning %d symbol(s) every %ds. Open bot trades: %d/%d.",
                             ArraySize(g_syms), InpScanIntervalSeconds, CountOpenBotTrades(), InpMaxOpenTrades);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   string liveFlag = InpConfirmLiveRiskUnderstood ? "LIVE ORDERS ENABLED" : "LIVE ORDERS DISABLED (proposals only)";

   Comment(StringFormat("TrendSignalBot\n%s\nBalance: %.2f  Equity: %.2f\n%s",
                         status, balance, equity, liveFlag));
  }
//+------------------------------------------------------------------+
