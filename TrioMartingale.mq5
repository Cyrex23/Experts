//+------------------------------------------------------------------+
//|                          TrioMartingale.mq5                      |
//|        AUDNZD + NZDCAD + AUDCAD  Martingale Grid EA             |
//|                                                                  |
//|  Strategy overview:                                              |
//|  - Trades three correlated pairs simultaneously                  |
//|  - Enters on mean-reversion signals (RSI extremes)              |
//|  - Uses martingale grid: doubles lot when price moves against    |
//|  - Closes group when price recovers to avg entry + TP pips      |
//|  - Emergency close of ALL positions at max drawdown %           |
//|  - Designed for $10,000 account with 1:250 or 1:500 leverage    |
//+------------------------------------------------------------------+
#property copyright   "Trio Martingale EA"
#property description "Martingale grid for AUDNZD / NZDCAD / AUDCAD trio"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//-------------------------------------------------------------------
// INPUT PARAMETERS
//-------------------------------------------------------------------

input group "=== Symbol Settings ==="
input string InpSuffix        = ".r";    // Broker symbol suffix (e.g. ".r", leave blank if none)

input group "=== Position Sizing ==="
input double InpBaseLot       = 0.01;   // Base lot size (first entry per grid)
input double InpMultiplier    = 2.0;    // Martingale multiplier per level
input int    InpMaxLevels     = 8;      // Maximum martingale levels per direction

input group "=== Entry Signal (H1) ==="
input int    InpRSIPeriod     = 14;     // RSI period
input double InpRSIBuyLevel   = 35.0;   // RSI below this → BUY signal (oversold)
input double InpRSISellLevel  = 65.0;   // RSI above this → SELL signal (overbought)
input int    InpMAPeriod      = 50;     // MA period (trend filter)

input group "=== Grid & Take Profit ==="
input int    InpGridPips      = 25;     // Pips between martingale levels
input int    InpTPPips        = 15;     // Take profit pips above/below VWAP
input int    InpCooldownMin   = 45;     // Minutes between new independent entries (same sym/dir)

input group "=== Risk Management ==="
input double InpMaxDDPct      = 55.0;   // Max drawdown % → close ALL positions
input double InpHedgeDDPct    = 35.0;   // Drawdown % to pause new entries
input int    InpMaxTotalPos   = 24;     // Hard cap on total open positions

input group "=== Expert Settings ==="
input int    InpMagicBase     = 202400; // Base magic number (each pair gets +0/+1/+2)
input int    InpSlippage      = 30;     // Maximum slippage (points)

//-------------------------------------------------------------------
// CONSTANTS & GLOBALS
//-------------------------------------------------------------------

#define NUM_SYMS 3
string BaseNames[NUM_SYMS] = {"AUDNZD", "NZDCAD", "AUDCAD"};
string Syms[NUM_SYMS];         // Resolved symbol names (with suffix if needed)
bool   SymOK[NUM_SYMS];        // Whether symbol was found

// Cached indicator handles (per symbol, created once in OnInit)
int HndRSI[NUM_SYMS];
int HndMA[NUM_SYMS];

// Cooldown timestamps [symbol][0=buy, 1=sell]
datetime LastEntry[NUM_SYMS][2];

CTrade        Trade;
CPositionInfo PosInf;
CAccountInfo  AccInf;

//-------------------------------------------------------------------
// DATA STRUCTURES
//-------------------------------------------------------------------

// Aggregated info about one group of positions (same sym+magic+direction)
struct GroupInfo {
    int    count;        // Number of open positions
    double totalLots;    // Sum of all volumes
    double totalPL;      // Unrealized P&L (profit + swap + commission)
    double vwap;         // Volume-weighted average open price
    double maxLot;       // Largest single position volume
    double extremePrice; // Most adverse price: lowest for buys, highest for sells
};

//-------------------------------------------------------------------
// INITIALIZATION
//-------------------------------------------------------------------

int OnInit()
{
    // --- Resolve symbol names ---
    for(int i = 0; i < NUM_SYMS; i++)
    {
        HndRSI[i] = INVALID_HANDLE;
        HndMA[i]  = INVALID_HANDLE;
        SymOK[i]  = false;

        string candidate = BaseNames[i] + InpSuffix;
        if(SymbolSelect(candidate, true) && SymbolInfoDouble(candidate, SYMBOL_BID) > 0)
        {
            Syms[i] = candidate;
            SymOK[i] = true;
        }
        else
        {
            // Fall back to base name without suffix
            candidate = BaseNames[i];
            if(SymbolSelect(candidate, true) && SymbolInfoDouble(candidate, SYMBOL_BID) > 0)
            {
                Syms[i] = candidate;
                SymOK[i] = true;
            }
        }

        if(!SymOK[i])
        {
            Print("WARNING: Cannot find symbol for ", BaseNames[i],
                  ". Tried '", BaseNames[i] + InpSuffix, "' and '", BaseNames[i], "'.");
            continue;
        }
        Print("Symbol OK: ", Syms[i]);

        // --- Create indicator handles on H1 ---
        HndRSI[i] = iRSI(Syms[i], PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
        HndMA[i]  = iMA(Syms[i],  PERIOD_H1, InpMAPeriod,  0, MODE_EMA, PRICE_CLOSE);

        if(HndRSI[i] == INVALID_HANDLE || HndMA[i] == INVALID_HANDLE)
        {
            Print("FATAL: Could not create indicators for ", Syms[i]);
            return INIT_FAILED;
        }
    }

    // --- Init cooldown timestamps ---
    for(int i = 0; i < NUM_SYMS; i++)
        for(int d = 0; d < 2; d++)
            LastEntry[i][d] = 0;

    Trade.SetDeviationInPoints(InpSlippage);

    Print("TrioMartingale initialized | Balance: ", AccInf.Balance(),
          " | Leverage: 1:", AccInf.Leverage(),
          " | MaxLevels: ", InpMaxLevels,
          " | GridPips: ", InpGridPips,
          " | TPPips: ", InpTPPips);

    return INIT_SUCCEEDED;
}

//-------------------------------------------------------------------
// DEINITIALIZATION
//-------------------------------------------------------------------

void OnDeinit(const int reason)
{
    for(int i = 0; i < NUM_SYMS; i++)
    {
        if(HndRSI[i] != INVALID_HANDLE) { IndicatorRelease(HndRSI[i]); HndRSI[i] = INVALID_HANDLE; }
        if(HndMA[i]  != INVALID_HANDLE) { IndicatorRelease(HndMA[i]);  HndMA[i]  = INVALID_HANDLE; }
    }
}

//-------------------------------------------------------------------
// HELPER: Normalize lot to broker constraints
//-------------------------------------------------------------------

double NormLot(string sym, double lot)
{
    double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
    lot = MathFloor(lot / step) * step;
    return MathMax(mn, MathMin(mx, lot));
}

//-------------------------------------------------------------------
// HELPER: Pip size (handles 5-digit and 4-digit brokers)
//-------------------------------------------------------------------

double PipSz(string sym)
{
    double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
    return (digits == 5 || digits == 3) ? pt * 10.0 : pt;
}

//-------------------------------------------------------------------
// HELPER: Read a single indicator buffer value (bar shift)
//-------------------------------------------------------------------

double BufVal(int handle, int shift)
{
    if(handle == INVALID_HANDLE) return 0.0;
    double buf[1];
    if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return 0.0;
    return buf[0];
}

//-------------------------------------------------------------------
// HELPER: Collect aggregated group info for one symbol/direction
//-------------------------------------------------------------------

GroupInfo GetGroup(int symIdx, ENUM_POSITION_TYPE pType)
{
    GroupInfo g;
    g.count        = 0;
    g.totalLots    = 0.0;
    g.totalPL      = 0.0;
    g.vwap         = 0.0;
    g.maxLot       = 0.0;
    g.extremePrice = 0.0;

    string sym   = Syms[symIdx];
    int    magic = InpMagicBase + symIdx;
    double sumPL = 0.0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!PosInf.SelectByIndex(i))    continue;
        if(PosInf.Symbol()  != sym)     continue;
        if(PosInf.Magic()   != magic)   continue;
        if(PosInf.PositionType() != pType) continue;

        double vol  = PosInf.Volume();
        double open = PosInf.PriceOpen();
        double pl   = PosInf.Profit() + PosInf.Swap() + PosInf.Commission();

        g.count++;
        g.totalLots += vol;
        g.totalPL   += pl;
        sumPL       += open * vol;
        if(vol > g.maxLot) g.maxLot = vol;

        // Track most adverse open price
        if(pType == POSITION_TYPE_BUY)
        {
            // Worst = lowest price opened (most underwater)
            if(g.extremePrice == 0.0 || open < g.extremePrice)
                g.extremePrice = open;
        }
        else
        {
            // Worst = highest price opened
            if(g.extremePrice == 0.0 || open > g.extremePrice)
                g.extremePrice = open;
        }
    }

    if(g.totalLots > 0.0)
        g.vwap = sumPL / g.totalLots;

    return g;
}

//-------------------------------------------------------------------
// HELPER: Close all positions for one symbol/direction
//-------------------------------------------------------------------

void CloseGroup(int symIdx, ENUM_POSITION_TYPE pType)
{
    string sym   = Syms[symIdx];
    int    magic = InpMagicBase + symIdx;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!PosInf.SelectByIndex(i))         continue;
        if(PosInf.Symbol()  != sym)          continue;
        if(PosInf.Magic()   != magic)        continue;
        if(PosInf.PositionType() != pType)   continue;

        bool ok = Trade.PositionClose(PosInf.Ticket());
        if(!ok)
            Print("CloseGroup failed ticket=", PosInf.Ticket(),
                  " err=", Trade.ResultRetcode());
    }
}

//-------------------------------------------------------------------
// HELPER: Emergency close of ALL open positions
//-------------------------------------------------------------------

void CloseAll(string reason)
{
    Print("CloseAll triggered: ", reason);
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PosInf.SelectByIndex(i))
            Trade.PositionClose(PosInf.Ticket());
    }
}

//-------------------------------------------------------------------
// HELPER: Current account drawdown % (balance vs equity)
//-------------------------------------------------------------------

double DrawdownPct()
{
    double bal = AccInf.Balance();
    double eq  = AccInf.Equity();
    if(bal <= 0.0) return 0.0;
    double dd = (bal - eq) / bal * 100.0;
    return MathMax(dd, 0.0);
}

//-------------------------------------------------------------------
// HELPER: Check if market appears open (non-zero bid, low spread)
//-------------------------------------------------------------------

bool MarketOpen(string sym)
{
    double bid = SymbolInfoDouble(sym, SYMBOL_BID);
    double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    if(bid <= 0.0 || ask <= 0.0) return false;
    // If spread is extremely wide the market is likely closed
    double maxSpreadPips = 10.0;
    double pip = PipSz(sym);
    return ((ask - bid) < maxSpreadPips * pip);
}

//-------------------------------------------------------------------
// CORE: Process one symbol (manage existing groups + open new entries)
//-------------------------------------------------------------------

void ProcessSymbol(int idx, double ddPct)
{
    if(!SymOK[idx]) return;

    string sym   = Syms[idx];
    int    magic = InpMagicBase + idx;

    if(!MarketOpen(sym)) return;

    Trade.SetExpertMagicNumber(magic);

    double pip = PipSz(sym);
    double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    double bid = SymbolInfoDouble(sym, SYMBOL_BID);

    GroupInfo bg = GetGroup(idx, POSITION_TYPE_BUY);
    GroupInfo sg = GetGroup(idx, POSITION_TYPE_SELL);

    //================================================================
    // MANAGE EXISTING BUY GROUP
    //================================================================
    if(bg.count > 0)
    {
        double tpLevel = bg.vwap + InpTPPips * pip;

        if(bid >= tpLevel)
        {
            // Price recovered to VWAP + TP — take profit
            Print(sym, " BUY group TP | levels=", bg.count,
                  " lots=", bg.totalLots,
                  " vwap=", DoubleToString(bg.vwap, 5),
                  " bid=", DoubleToString(bid, 5),
                  " PL=", DoubleToString(bg.totalPL, 2));
            CloseGroup(idx, POSITION_TYPE_BUY);
        }
        else if(bg.count < InpMaxLevels)
        {
            // Price dropped GridPips below last (extreme) entry → add martingale level
            double triggerPrice = bg.extremePrice - InpGridPips * pip;
            if(ask <= triggerPrice)
            {
                double nextLot = NormLot(sym, bg.maxLot * InpMultiplier);
                if(Trade.Buy(nextLot, sym, ask, 0, 0,
                             "Mart_Buy_L" + IntegerToString(bg.count + 1)))
                {
                    Print(sym, " +BUY level ", bg.count + 1,
                          " lot=", nextLot,
                          " ask=", DoubleToString(ask, 5),
                          " extremeWas=", DoubleToString(bg.extremePrice, 5));
                }
                else
                    Print(sym, " BUY add failed: ", Trade.ResultRetcodeDescription());
            }
        }
        else
        {
            // Max levels reached — just wait for recovery
            if(bg.totalPL < 0.0)
                PrintFormat("%s BUY maxed out (%d levels, %.2f PL) – waiting recovery",
                            sym, bg.count, bg.totalPL);
        }
    }

    //================================================================
    // MANAGE EXISTING SELL GROUP
    //================================================================
    if(sg.count > 0)
    {
        double tpLevel = sg.vwap - InpTPPips * pip;

        if(ask <= tpLevel)
        {
            // Price dropped to VWAP - TP — take profit
            Print(sym, " SELL group TP | levels=", sg.count,
                  " lots=", sg.totalLots,
                  " vwap=", DoubleToString(sg.vwap, 5),
                  " ask=", DoubleToString(ask, 5),
                  " PL=", DoubleToString(sg.totalPL, 2));
            CloseGroup(idx, POSITION_TYPE_SELL);
        }
        else if(sg.count < InpMaxLevels)
        {
            // Price rose GridPips above last (extreme) entry → add martingale level
            double triggerPrice = sg.extremePrice + InpGridPips * pip;
            if(bid >= triggerPrice)
            {
                double nextLot = NormLot(sym, sg.maxLot * InpMultiplier);
                if(Trade.Sell(nextLot, sym, bid, 0, 0,
                              "Mart_Sell_L" + IntegerToString(sg.count + 1)))
                {
                    Print(sym, " +SELL level ", sg.count + 1,
                          " lot=", nextLot,
                          " bid=", DoubleToString(bid, 5),
                          " extremeWas=", DoubleToString(sg.extremePrice, 5));
                }
                else
                    Print(sym, " SELL add failed: ", Trade.ResultRetcodeDescription());
            }
        }
        else
        {
            if(sg.totalPL < 0.0)
                PrintFormat("%s SELL maxed out (%d levels, %.2f PL) – waiting recovery",
                            sym, sg.count, sg.totalPL);
        }
    }

    //================================================================
    // OPEN NEW ENTRY (only if no group open in that direction)
    //================================================================

    // Pause new entries when account drawdown is too high
    if(ddPct >= InpHedgeDDPct) return;

    // Hard cap on total position count
    if(PositionsTotal() >= InpMaxTotalPos) return;

    // Read indicators (shift=1 → last closed H1 bar)
    double rsi = BufVal(HndRSI[idx], 1);
    double ma  = BufVal(HndMA[idx],  1);
    if(rsi <= 0.0 || ma <= 0.0) return; // Not enough history yet

    datetime now = TimeCurrent();
    long cooldownSec = (long)InpCooldownMin * 60;

    //--- NEW BUY ENTRY ---
    if(bg.count == 0)
    {
        bool signalOK  = (rsi < InpRSIBuyLevel && bid < ma);
        bool cooldownOK = (now - LastEntry[idx][0]) >= cooldownSec;

        if(signalOK && cooldownOK)
        {
            double lot = NormLot(sym, InpBaseLot);
            if(Trade.Buy(lot, sym, ask, 0, 0, "Entry_Buy"))
            {
                LastEntry[idx][0] = now;
                Print(sym, " NEW BUY entry | lot=", lot,
                      " RSI=", DoubleToString(rsi, 1),
                      " MA=",  DoubleToString(ma, 5),
                      " ask=", DoubleToString(ask, 5));
            }
        }
    }

    //--- NEW SELL ENTRY ---
    if(sg.count == 0)
    {
        bool signalOK   = (rsi > InpRSISellLevel && bid > ma);
        bool cooldownOK = (now - LastEntry[idx][1]) >= cooldownSec;

        if(signalOK && cooldownOK)
        {
            double lot = NormLot(sym, InpBaseLot);
            if(Trade.Sell(lot, sym, bid, 0, 0, "Entry_Sell"))
            {
                LastEntry[idx][1] = now;
                Print(sym, " NEW SELL entry | lot=", lot,
                      " RSI=", DoubleToString(rsi, 1),
                      " MA=",  DoubleToString(ma, 5),
                      " bid=", DoubleToString(bid, 5));
            }
        }
    }
}

//-------------------------------------------------------------------
// MAIN TICK
//-------------------------------------------------------------------

void OnTick()
{
    // Throttle: process at most once every 5 seconds to save CPU
    static datetime lastTick = 0;
    datetime now = TimeCurrent();
    if(now - lastTick < 5 && lastTick != 0) return;
    lastTick = now;

    //--- Emergency drawdown check ---
    double dd = DrawdownPct();
    if(dd >= InpMaxDDPct)
    {
        CloseAll(StringFormat("Max drawdown %.1f%% reached (limit %.1f%%)", dd, InpMaxDDPct));
        return;
    }

    //--- Process each symbol ---
    for(int i = 0; i < NUM_SYMS; i++)
        ProcessSymbol(i, dd);
}

//-------------------------------------------------------------------
// TRADE EVENT — log fills for diagnostics
//-------------------------------------------------------------------

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        // Optionally log fills here
    }
}
