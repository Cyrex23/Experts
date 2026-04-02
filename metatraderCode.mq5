//+------------------------------------------------------------------+
//|           Tri Arb AUDNZD/AUDCAD/NZDCAD - Mean Reversion EA      |
//|           Triangular Arbitrage on AUD/NZD/CAD Triangle           |
//|           v3.0 - Optimized for Profitability                     |
//+------------------------------------------------------------------+
#property copyright "Tri Arb Strategy"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input group "=== Pair Configuration ==="
input string InpAUDNZD       = "AUDNZD";    // AUDNZD Symbol
input string InpNZDCAD       = "NZDCAD";    // NZDCAD Symbol
// AUDCAD is the chart symbol

input group "=== Spread Settings ==="
input int    InpSpreadLen    = 500;          // Spread MA Length (longer = more stable mean)
input int    InpSpreadLenFast= 50;           // Fast Spread MA (for momentum confirmation)
input double InpEntryZ       = 3.5;         // Entry Threshold (Std Devs)
input double InpExitZ        = 0.0;         // Exit Threshold (at mean = 0.0)
input double InpReEntryZ     = 4.5;         // Re-entry on extreme (add to winner)

input group "=== Position Sizing ==="
input double InpBaseLots     = 0.01;        // Base Lot Size
input double InpRiskPct      = 1.5;         // Risk % of Equity
input bool   InpUseFixedLots = true;        // Use Fixed Lots (vs Risk%)

input group "=== Profit Management ==="
input double InpScalpTarget  = 0.0;         // Scalp Target % (0=disabled, use mean rev only)
input double InpTrailStart   = 0.30;        // Trailing Start % profit
input double InpTrailStep    = 0.10;        // Trailing Step %
input int    InpMaxHoldBars  = 0;           // Max Hold Bars (0=disabled)
input int    InpMinHoldBars  = 5;           // Min Hold Bars before exit

input group "=== Filters ==="
input int    InpVolatilityLen  = 100;       // Volatility lookback
input double InpMinVolatility  = 0.0001;    // Min spread volatility to trade
input double InpMaxVolatility  = 0.01;      // Max spread volatility (avoid chaos)
input bool   InpUseSessionFilter = true;    // Filter by trading session
input int    InpSessionStartHour = 2;       // Session start (GMT) - London pre-open
input int    InpSessionEndHour   = 20;      // Session end (GMT)

input group "=== Risk Management ==="
input double InpMaxDDPct      = 15.0;       // Max Drawdown %
input int    InpCooldownBars  = 48;         // Cooldown Bars After DD Stop
input double InpMaxSpreadPips = 2.0;        // Max Spread to Enter (pips)
input double InpStopLossPct   = 0.5;        // Stop Loss % per trade
input int    InpMaxDailyTrades = 10;        // Max trades per day
input double InpMaxDailyLoss   = 1.0;       // Max daily loss %

input group "=== General ==="
input int    InpMagicNumber   = 789456;     // Magic Number
input int    InpSlippage      = 10;         // Max Slippage (points)

//--- Global Variables
CTrade         trade;
CSymbolInfo    symAUDCAD, symAUDNZD, symNZDCAD;
CAccountInfo   account;
CPositionInfo  position;

int    g_direction     = 0;      // 0=flat, 1=long spread, -1=short spread
int    g_entryBarIdx   = 0;
double g_entryZscore   = 0.0;
double g_entrySpread   = 0.0;
double g_bestPnlPct    = 0.0;    // For trailing
double g_trailLevel    = 0.0;    // Trailing stop level
bool   g_ddFlag        = false;
int    g_ddCoolEnd     = 0;
double g_peakEquity    = 0.0;
double g_dayStartEquity= 0.0;
int    g_dailyTrades   = 0;
int    g_lastTradeDay  = 0;

//--- Spread history ring buffer
double g_spreadBuf[];
int    g_spreadIdx     = 0;
int    g_spreadCount   = 0;
datetime g_lastBarTime = 0;

//--- Performance tracking
int    g_totalWins     = 0;
int    g_totalLosses   = 0;
double g_totalPnL      = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!SymbolSelect(InpAUDNZD, true))
   {
      Print("ERROR: Cannot find symbol ", InpAUDNZD);
      return INIT_FAILED;
   }
   if(!SymbolSelect(InpNZDCAD, true))
   {
      Print("ERROR: Cannot find symbol ", InpNZDCAD);
      return INIT_FAILED;
   }
   
   symAUDCAD.Name(_Symbol);
   symAUDNZD.Name(InpAUDNZD);
   symNZDCAD.Name(InpNZDCAD);
   
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   ArrayResize(g_spreadBuf, InpSpreadLen);
   ArrayInitialize(g_spreadBuf, 0.0);
   g_spreadIdx   = 0;
   g_spreadCount = 0;
   
   g_peakEquity    = account.Equity();
   g_dayStartEquity= account.Equity();
   
   RestoreState();
   
   Print("Tri Arb EA v3.0 OPTIMIZED initialized on ", _Symbol);
   Print("Triangle: ", _Symbol, " = ", InpAUDNZD, " x ", InpNZDCAD);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print("=== FINAL STATS === Wins:", g_totalWins, " Losses:", g_totalLosses, 
         " PnL:", DoubleToString(g_totalPnL, 2));
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime)
      return;
   g_lastBarTime = currentBarTime;
   
   // Reset daily counters
   MqlDateTime dt;
   TimeToStruct(currentBarTime, dt);
   int today = dt.day_of_year;
   if(today != g_lastTradeDay)
   {
      g_lastTradeDay   = today;
      g_dailyTrades    = 0;
      g_dayStartEquity = account.Equity();
   }
   
   // Refresh all symbol data
   symAUDCAD.RefreshRates();
   symAUDNZD.RefreshRates();
   symNZDCAD.RefreshRates();
   
   // Get prices - use mid for calculation
   double audcadBid = symAUDCAD.Bid();
   double audcadAsk = symAUDCAD.Ask();
   double audnzdBid = symAUDNZD.Bid();
   double audnzdAsk = symAUDNZD.Ask();
   double nzdcadBid = symNZDCAD.Bid();
   double nzdcadAsk = symNZDCAD.Ask();
   
   double audcadMid = (audcadBid + audcadAsk) / 2.0;
   double audnzdMid = (audnzdBid + audnzdAsk) / 2.0;
   double nzdcadMid = (nzdcadBid + nzdcadAsk) / 2.0;
   
   if(audcadMid <= 0 || audnzdMid <= 0 || nzdcadMid <= 0)
      return;
   
   //--- Calculate spread
   double rawSpread = MathLog(audcadMid) - MathLog(audnzdMid) - MathLog(nzdcadMid);
   
   // Add to ring buffer
   g_spreadBuf[g_spreadIdx] = rawSpread;
   g_spreadIdx = (g_spreadIdx + 1) % InpSpreadLen;
   if(g_spreadCount < InpSpreadLen)
      g_spreadCount++;
   
   if(g_spreadCount < InpSpreadLen)
   {
      Comment("Warming up: ", g_spreadCount, "/", InpSpreadLen, " bars");
      return;
   }
   
   //--- Calculate slow z-score (main signal)
   double spreadMA = 0.0, spreadSD = 0.0;
   CalcStats(spreadMA, spreadSD, InpSpreadLen);
   
   if(spreadSD <= 0)
      return;
   
   double zScore = (rawSpread - spreadMA) / spreadSD;
   
   //--- Calculate fast z-score (momentum confirmation)
   double fastMA = 0.0, fastSD = 0.0;
   CalcStats(fastMA, fastSD, InpSpreadLenFast);
   double zScoreFast = (fastSD > 0) ? (rawSpread - fastMA) / fastSD : 0.0;
   
   //--- Volatility filter
   double spreadVol = spreadSD;
   bool volOK = (spreadVol >= InpMinVolatility && spreadVol <= InpMaxVolatility);
   
   //--- Session filter
   bool sessionOK = true;
   if(InpUseSessionFilter)
   {
      int hour = dt.hour;
      sessionOK = (hour >= InpSessionStartHour && hour <= InpSessionEndHour);
   }
   
   //--- Bar index
   int barIdx = iBars(_Symbol, PERIOD_CURRENT);
   
   //--- Drawdown check
   double curEquity = account.Equity();
   if(curEquity > g_peakEquity)
      g_peakEquity = curEquity;
   
   double ddPct = (g_peakEquity > 0) ? ((g_peakEquity - curEquity) / g_peakEquity) * 100.0 : 0.0;
   bool   ddStop = (ddPct >= InpMaxDDPct);
   bool   coolActive = g_ddFlag && (barIdx < g_ddCoolEnd);
   
   if(g_ddFlag && barIdx >= g_ddCoolEnd)
      g_ddFlag = false;
   
   //--- Daily loss check
   double dailyPnL = curEquity - g_dayStartEquity;
   double dailyLossPct = (g_dayStartEquity > 0) ? (MathAbs(dailyPnL) / g_dayStartEquity) * 100.0 : 0.0;
   bool dailyLossStop = (dailyPnL < 0 && dailyLossPct >= InpMaxDailyLoss);
   
   //--- Daily trade limit
   bool dailyTradeLimit = (g_dailyTrades >= InpMaxDailyTrades);
   
   //--- DD Emergency Close
   if(ddStop && g_direction != 0)
   {
      Print("DD STOP at ", DoubleToString(ddPct, 1), "%");
      CloseAllTriArb("DD STOP");
      ResetState();
      g_ddFlag    = true;
      g_ddCoolEnd = barIdx + InpCooldownBars;
      return;
   }
   
   //--- Spread check for all 3 pairs
   double audcadSpreadPips = (audcadAsk - audcadBid) / symAUDCAD.Point();
   double audnzdSpreadPips = (audnzdAsk - audnzdBid) / symAUDNZD.Point();
   double nzdcadSpreadPips = (nzdcadAsk - nzdcadBid) / symNZDCAD.Point();
   bool   spreadOK = (audcadSpreadPips <= InpMaxSpreadPips * 10 && 
                       audnzdSpreadPips <= InpMaxSpreadPips * 10 && 
                       nzdcadSpreadPips <= InpMaxSpreadPips * 10);
   
   //--- Momentum confirmation: fast z should agree with slow z direction
   bool momentumConfirmLong  = (zScoreFast < -1.5);  // Fast also showing oversold
   bool momentumConfirmShort = (zScoreFast > 1.5);   // Fast also showing overbought
   
   //--- Combined entry filter
   bool canEnter = (!coolActive && !ddStop && !dailyLossStop && !dailyTradeLimit && 
                    spreadOK && volOK && sessionOK && g_direction == 0);
   
   //--- Entry signals
   bool longSpread  = (zScore < -InpEntryZ) && momentumConfirmLong;
   bool shortSpread = (zScore >  InpEntryZ) && momentumConfirmShort;
   
   //--- Lot sizes
   double lotsAUDCAD = GetLots(_Symbol);
   double lotsAUDNZD = GetLots(InpAUDNZD);
   double lotsNZDCAD = GetLots(InpNZDCAD);
   
   //--- ENTRY: Long spread (spread too low, expect rise)
   if(longSpread && canEnter)
   {
      // BUY AUDCAD, SELL AUDNZD, SELL NZDCAD
      bool leg1 = trade.Buy(lotsAUDCAD, _Symbol, 0, 0, 0, "TRI+ AUDCAD z=" + DoubleToString(zScore, 2));
      bool leg2 = trade.Sell(lotsAUDNZD, InpAUDNZD, 0, 0, 0, "TRI+ AUDNZD z=" + DoubleToString(zScore, 2));
      bool leg3 = trade.Sell(lotsNZDCAD, InpNZDCAD, 0, 0, 0, "TRI+ NZDCAD z=" + DoubleToString(zScore, 2));
      
      if(leg1 && leg2 && leg3)
      {
         g_direction   = 1;
         g_entryBarIdx = barIdx;
         g_entryZscore = zScore;
         g_entrySpread = rawSpread;
         g_bestPnlPct  = 0.0;
         g_trailLevel  = -999.0;
         g_dailyTrades++;
         Print("=== LONG SPREAD Z=", DoubleToString(zScore, 3), " FastZ=", DoubleToString(zScoreFast, 3), " ===");
      }
      else
      {
         CloseAllTriArb("PARTIAL FILL");
      }
   }
   
   //--- ENTRY: Short spread (spread too high, expect fall)
   if(shortSpread && canEnter)
   {
      // SELL AUDCAD, BUY AUDNZD, BUY NZDCAD
      bool leg1 = trade.Sell(lotsAUDCAD, _Symbol, 0, 0, 0, "TRI- AUDCAD z=" + DoubleToString(zScore, 2));
      bool leg2 = trade.Buy(lotsAUDNZD, InpAUDNZD, 0, 0, 0, "TRI- AUDNZD z=" + DoubleToString(zScore, 2));
      bool leg3 = trade.Buy(lotsNZDCAD, InpNZDCAD, 0, 0, 0, "TRI- NZDCAD z=" + DoubleToString(zScore, 2));
      
      if(leg1 && leg2 && leg3)
      {
         g_direction   = -1;
         g_entryBarIdx = barIdx;
         g_entryZscore = zScore;
         g_entrySpread = rawSpread;
         g_bestPnlPct  = 0.0;
         g_trailLevel  = -999.0;
         g_dailyTrades++;
         Print("=== SHORT SPREAD Z=", DoubleToString(zScore, 3), " FastZ=", DoubleToString(zScoreFast, 3), " ===");
      }
      else
      {
         CloseAllTriArb("PARTIAL FILL");
      }
   }
   
   //--- EXIT LOGIC
   if(g_direction != 0)
   {
      int barsHeld = barIdx - g_entryBarIdx;
      
      // Get actual P&L
      double totalProfit = GetTriArbProfit();
      double equity = account.Equity();
      double pnlPct = (equity > 0) ? (totalProfit / equity) * 100.0 : 0.0;
      
      // Track best P&L for trailing
      if(pnlPct > g_bestPnlPct)
         g_bestPnlPct = pnlPct;
      
      //--- Exit conditions
      bool exitMeanRev = false;
      bool exitScalp   = false;
      bool exitTimeout = false;
      bool exitStopLoss= false;
      bool exitTrail   = false;
      bool exitDailyLoss = false;
      
      // 1. Mean reversion: z-score crossed back to zero (primary exit)
      if(barsHeld >= InpMinHoldBars)
      {
         if(g_direction == 1)
            exitMeanRev = (zScore >= InpExitZ);
         else if(g_direction == -1)
            exitMeanRev = (zScore <= -InpExitZ);
      }
      
      // 2. Scalp target (if enabled)
      if(InpScalpTarget > 0 && pnlPct >= InpScalpTarget && barsHeld >= InpMinHoldBars)
         exitScalp = true;
      
      // 3. Trailing stop: lock in profits
      if(g_bestPnlPct >= InpTrailStart && barsHeld >= InpMinHoldBars)
      {
         double newTrail = g_bestPnlPct - InpTrailStep;
         if(newTrail > g_trailLevel)
            g_trailLevel = newTrail;
         
         if(pnlPct <= g_trailLevel && g_trailLevel > 0)
            exitTrail = true;
      }
      
      // 4. Timeout (if enabled)
      if(InpMaxHoldBars > 0 && barsHeld >= InpMaxHoldBars)
         exitTimeout = true;
      
      // 5. Stop loss
      if(pnlPct <= -InpStopLossPct)
         exitStopLoss = true;
      
      // 6. Daily loss limit while in position
      if(dailyLossStop)
         exitDailyLoss = true;
      
      //--- Execute exit
      if(exitMeanRev || exitScalp || exitTrail || exitTimeout || exitStopLoss || exitDailyLoss)
      {
         string exitReason = "UNKNOWN";
         if(exitMeanRev)    exitReason = "MEAN REVERSION";
         if(exitScalp)      exitReason = "SCALP TARGET";
         if(exitTrail)      exitReason = "TRAILING STOP";
         if(exitTimeout)    exitReason = "TIMEOUT";
         if(exitStopLoss)   exitReason = "STOP LOSS";
         if(exitDailyLoss)  exitReason = "DAILY LOSS LIMIT";
         
         // Track stats
         if(totalProfit > 0)
            g_totalWins++;
         else
            g_totalLosses++;
         g_totalPnL += totalProfit;
         
         Print("=== EXIT: ", exitReason, " === PnL=$", DoubleToString(totalProfit, 2), 
               " (", DoubleToString(pnlPct, 3), "%) Bars=", barsHeld,
               " Z=", DoubleToString(zScore, 3), " EntryZ=", DoubleToString(g_entryZscore, 3),
               " W/L=", g_totalWins, "/", g_totalLosses);
         
         CloseAllTriArb(exitReason);
         ResetState();
      }
   }
   
   //--- Dashboard
   string dashboard = "=== Tri Arb v3.0 OPTIMIZED ===\n";
   dashboard += "Z-Score: " + DoubleToString(zScore, 4) + " | Fast Z: " + DoubleToString(zScoreFast, 4) + "\n";
   dashboard += "Entry Z: ±" + DoubleToString(InpEntryZ, 1) + " | Exit Z: ±" + DoubleToString(InpExitZ, 1) + "\n";
   dashboard += "Direction: " + (g_direction == 1 ? "LONG SPREAD" : g_direction == -1 ? "SHORT SPREAD" : "FLAT") + "\n";
   
   if(g_direction != 0)
   {
      double triProfit = GetTriArbProfit();
      double pnl = (curEquity > 0) ? (triProfit / curEquity) * 100.0 : 0.0;
      dashboard += "P&L: $" + DoubleToString(triProfit, 2) + " (" + DoubleToString(pnl, 3) + "%)\n";
      dashboard += "Best P&L: " + DoubleToString(g_bestPnlPct, 3) + "% | Trail: " + 
                   (g_trailLevel > -999 ? DoubleToString(g_trailLevel, 3) + "%" : "—") + "\n";
      dashboard += "Bars Held: " + IntegerToString(iBars(_Symbol, PERIOD_CURRENT) - g_entryBarIdx) + "\n";
   }
   
   dashboard += "Volatility: " + DoubleToString(spreadVol, 6) + (volOK ? " ✓" : " ✗") + "\n";
   dashboard += "Session: " + (sessionOK ? "ACTIVE" : "CLOSED") + "\n";
   dashboard += "DD: " + DoubleToString(ddPct, 1) + "% / " + DoubleToString(InpMaxDDPct, 0) + "%\n";
   dashboard += "Daily: " + IntegerToString(g_dailyTrades) + "/" + IntegerToString(InpMaxDailyTrades) + " trades\n";
   dashboard += "Stats: W" + IntegerToString(g_totalWins) + " L" + IntegerToString(g_totalLosses) + 
                " PnL=$" + DoubleToString(g_totalPnL, 2) + "\n";
   dashboard += "Equity: $" + DoubleToString(curEquity, 2) + "\n";
   Comment(dashboard);
}

//+------------------------------------------------------------------+
//| Calculate mean and std dev from ring buffer                       |
//+------------------------------------------------------------------+
void CalcStats(double &mean, double &stddev, int length)
{
   mean   = 0.0;
   stddev = 0.0;
   
   int actualLen = MathMin(length, g_spreadCount);
   if(actualLen < 10)
      return;
   
   // Calculate from most recent values
   double sum = 0.0;
   for(int i = 0; i < actualLen; i++)
   {
      int idx = (g_spreadIdx - 1 - i + InpSpreadLen) % InpSpreadLen;
      sum += g_spreadBuf[idx];
   }
   mean = sum / actualLen;
   
   double sumSq = 0.0;
   for(int i = 0; i < actualLen; i++)
   {
      int idx = (g_spreadIdx - 1 - i + InpSpreadLen) % InpSpreadLen;
      double diff = g_spreadBuf[idx] - mean;
      sumSq += diff * diff;
   }
   stddev = MathSqrt(sumSq / actualLen);
}

//+------------------------------------------------------------------+
//| Get lot size for a specific symbol                                |
//+------------------------------------------------------------------+
double GetLots(string symbol)
{
   double lots = InpBaseLots;
   
   if(!InpUseFixedLots)
   {
      double equity    = account.Equity();
      double riskMoney = equity * (InpRiskPct / 100.0);
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double bid       = SymbolInfoDouble(symbol, SYMBOL_BID);
      
      if(tickValue > 0 && tickSize > 0 && bid > 0)
      {
         double stopDist  = bid * (InpStopLossPct / 100.0);
         double ticksRisk = stopDist / tickSize;
         lots = (ticksRisk > 0) ? riskMoney / (ticksRisk * tickValue) : InpBaseLots;
      }
   }
   
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;
   
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   
   double marginReq = 0.0;
   double askPrice  = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(OrderCalcMargin(ORDER_TYPE_BUY, symbol, lots, askPrice, marginReq))
   {
      double freeMargin = account.FreeMargin();
      if(marginReq > freeMargin * 0.25)
      {
         if(freeMargin > 0 && marginReq > 0)
         {
            lots = lots * (freeMargin * 0.25) / marginReq;
            if(lotStep > 0)
               lots = MathFloor(lots / lotStep) * lotStep;
            lots = MathMax(lots, minLot);
         }
         else
            return 0.0;
      }
   }
   
   return lots;
}

//+------------------------------------------------------------------+
//| Get total unrealized profit from all tri-arb positions            |
//+------------------------------------------------------------------+
double GetTriArbProfit()
{
   double totalProfit = 0.0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Magic() == InpMagicNumber)
         {
            string posSymbol = position.Symbol();
            if(posSymbol == _Symbol || posSymbol == InpAUDNZD || posSymbol == InpNZDCAD)
            {
               totalProfit += position.Profit() + position.Swap() + position.Commission();
            }
         }
      }
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Close all tri-arb positions (all 3 legs)                         |
//+------------------------------------------------------------------+
void CloseAllTriArb(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Magic() == InpMagicNumber)
         {
            string posSymbol = position.Symbol();
            if(posSymbol == _Symbol || posSymbol == InpAUDNZD || posSymbol == InpNZDCAD)
            {
               double profit = position.Profit() + position.Swap() + position.Commission();
               trade.PositionClose(position.Ticket(), InpSlippage);
               Print("  Closed ", posSymbol, " P&L=$", DoubleToString(profit, 2), " [", reason, "]");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Reset internal state                                              |
//+------------------------------------------------------------------+
void ResetState()
{
   g_direction   = 0;
   g_entryBarIdx = 0;
   g_entryZscore = 0.0;
   g_entrySpread = 0.0;
   g_bestPnlPct  = 0.0;
   g_trailLevel  = -999.0;
}

//+------------------------------------------------------------------+
//| Restore state from existing positions (on restart)                |
//+------------------------------------------------------------------+
void RestoreState()
{
   int buyCount  = 0;
   int sellCount = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Magic() == InpMagicNumber)
         {
            string posSymbol = position.Symbol();
            if(posSymbol == _Symbol || posSymbol == InpAUDNZD || posSymbol == InpNZDCAD)
            {
               if(posSymbol == _Symbol)
               {
                  if(position.PositionType() == POSITION_TYPE_BUY)
                     buyCount++;
                  else
                     sellCount++;
               }
            }
         }
      }
   }
   
   if(buyCount > 0)
   {
      g_direction = 1;
      Print("Restored LONG SPREAD state");
   }
   else if(sellCount > 0)
   {
      g_direction = -1;
      Print("Restored SHORT SPREAD state");
   }
   
   g_peakEquity = account.Equity();
}
//+------------------------------------------------------------------+