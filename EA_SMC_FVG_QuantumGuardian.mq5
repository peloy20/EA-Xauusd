//+------------------------------------------------------------------+
//|                                               SMC FVG Guardian   |
//|                            by sansan x ChatGPT (Quantum style)   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "EA SMC + FVG + Dynamic Risk + Preset"
//--- trade library
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| ENUM & STRUCT                                                    |
//+------------------------------------------------------------------+
enum TrendBias
  {
   TREND_NONE = 0,
   TREND_BULL = 1,
   TREND_BEAR = -1
  };

enum RiskProfile
  {
   RISK_SAFE = 0,
   RISK_NORMAL = 1,
   RISK_AGGRESSIVE = 2
  };

// zona FVG sederhana
struct FVGZone
  {
   double    low;
   double    high;
   bool      bullish;
   datetime  time_bar;
  };

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
// General
input string   InpSymbol              = "XAUUSDm";
input ulong    InpMagic               = 777001;
input bool     InpUseCurrentSymbol    = true;

// Timeframe
input ENUM_TIMEFRAMES InpHTFTrendTF   = PERIOD_H1;   // TF trend
input ENUM_TIMEFRAMES InpSMCTF        = PERIOD_M15;  // TF struktur SMC (bisa diubah ke PERIOD_M5)
input ENUM_TIMEFRAMES InpFVGTF        = PERIOD_M5;   // TF FVG utama / eksekusi
input bool   InpWaitForCandleClose    = true;        // true = cek sinyal saat bar baru, false = intrabar entry

// Risk management (BASE, akan di-adjust oleh preset)
input double InpRiskPerTradePercent   = 1.0;    // 1-1.5% per trade
input bool   InpUseFixedLot           = true;
input double InpFixedLot              = 0.01;
input int    InpMaxOpenPositions      = 3;      // total posisi max
input double InpDailyLossLimitPercent = 8.0;    // stop trading jika loss harian >8%
input double InpMaxDrawdownPercent    = 25.0;   // stop trading jika DD >25%
input bool   InpCloseAllOnMaxDD       = true;   // close semua jika kena max DD

// RISK PROFILE PRESET
input RiskProfile InpRiskProfile      = RISK_SAFE;

// SMC settings
input bool   InpUseSMC                = true;
input int    InpSMCSwingLookback      = 20;     // jumlah candle untuk swing
input int    InpSMCMinSwingSizePoints = 200;    // minimal jarak swing (points)
input int    InpBiasEMAPeriod         = 50;     // EMA bias di HTF
input bool   InpOnlyTradeWithTrend    = true;   // hanya searah trend HTF

// FVG settings
input bool   InpUseFVG                = true;
input int    InpMinFVGPoints          = 50;     // minimal FVG (points)
input int    InpMaxFVGPoints          = 300;    // maksimal FVG (points)
input bool   InpRequirePremiumDiscount= true;   // hanya area premium/discount

// Entry & exit
input double InpRRRatio               = 2.0;    // RR 1:2
input double InpSLMinPoints           = 150;    // min SL (points)
input double InpSLMaxPoints           = 400;    // max SL
input bool   InpUseStructureSL        = true;   // SL di luar swing high/low
input bool   InpOneTradePerSetup      = true;   // 1 posisi per setup

// BreakEven & Trailing
input bool   InpUseBreakEven          = true;
input double InpBETriggerRR           = 1.0;    // BE saat profit >= 1R
input double InpBEOffsetPoints        = 20;     // offset setelah BE

input bool   InpUseATRTrailing        = true;
input int    InpATRPeriod             = 14;
input double InpATRTrailMultiplier    = 1.0;    // ATR x multiplier
input double InpATRTrailTriggerRR     = 1.5;    // mulai trailing di 1.5R
input bool   InpUseAdaptiveTrailing   = true;
input double InpATRFastMultiplier     = 0.8;
input double InpATRSlowMultiplier     = 1.5;
input double InpAdaptiveStartRR       = 1.0;    // mulai adaptif setelah 1R
input double InpAdaptiveStrongRR      = 2.0;    // trailing lebih ketat di atas 2R

// Compensation / Recovery (tanpa martingale)
input bool   InpUseCompensation       = true;
input int    InpMaxRecoveryAttempts   = 2;      // max re-entry setelah loss
input bool   InpIncreaseLotOnRecovery = false;  // untuk modal kecil: false

// Session & filters (BASE)
input bool   InpUseSessionFilter      = true;
input int    InpSessionStartHour      = 7;      // server time
input int    InpSessionEndHour        = 14;
input bool   InpUseAsiaNYFilter       = true;
input int    InpAsiaSessionStartHour  = 2;      // server time Asia session
input int    InpAsiaSessionEndHour    = 8;
input int    InpNYKillStartHour       = 13;     // New York Kill Zone start
input int    InpNYKillEndHour         = 17;

input bool   InpUseSpreadFilter       = true;
input int    InpMaxSpreadPoints       = 300;

input bool   InpUseATRVolFilter       = true;
input double InpATRVolMaxMultiplier   = 3.0;    // jika ATR > 3x rata2 -> pause

// Optional features
input bool   InpUseNewsFilter         = false;  // placeholder
input bool   InpUsePartialClose       = false;
input double InpPartialCloseAtRR      = 1.5;
input double InpPartialClosePercent   = 50.0;

input bool   InpStopAfterDailyProfit  = false;
input double InpDailyProfitTargetPct  = 10.0;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade      trade;
string      g_symbol;
TrendBias   g_TrendBias = TREND_NONE;

datetime    g_lastSignalBarTime = 0;

// Equity tracking
double      g_EquityHigh          = 0.0;
double      g_DailyStartEquity    = 0.0;
int         g_DailyDate           = 0;

// FVG storage
FVGZone     g_LastBullishFVG;
FVGZone     g_LastBearishFVG;

// SMC swings
double      g_LastSwingHighPrice  = 0.0;
datetime    g_LastSwingHighTime   = 0;
double      g_LastSwingLowPrice   = 0.0;
datetime    g_LastSwingLowTime    = 0;

// WORKING VARIABLES (dipengaruhi preset)
double      g_RiskPerTradePercent   = 1.0;
int         g_MaxOpenPositions      = 3;
double      g_DailyLossLimitPct     = 8.0;
double      g_MaxDrawdownPct        = 25.0;
double      g_ATRVolMaxMult         = 3.0;
int         g_SessionStartHour      = 7;
int         g_SessionEndHour        = 14;
int         g_ATRHandle_FVG         = INVALID_HANDLE;
int         g_ATRHandle_FVG_Long    = INVALID_HANDLE;
int         g_EMAHandle_HTF         = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Utility: Get current symbol                                      |
//+------------------------------------------------------------------+
string GetSymbol()
  {
   if(InpUseCurrentSymbol)
      return _Symbol;
   return InpSymbol;
  }

//+------------------------------------------------------------------+
//| Apply Risk Profile Preset                                       |
//+------------------------------------------------------------------+
void ApplyRiskPreset()
  {
   // default dari input
   g_RiskPerTradePercent = InpRiskPerTradePercent;
   g_MaxOpenPositions    = InpMaxOpenPositions;
   g_DailyLossLimitPct   = InpDailyLossLimitPercent;
   g_MaxDrawdownPct      = InpMaxDrawdownPercent;
   g_ATRVolMaxMult       = InpATRVolMaxMultiplier;
   g_SessionStartHour    = InpSessionStartHour;
   g_SessionEndHour      = InpSessionEndHour;

   switch(InpRiskProfile)
     {
      case RISK_SAFE:
         g_RiskPerTradePercent = MathMin(g_RiskPerTradePercent, 0.5);   // max 0.5% / trade
         g_MaxOpenPositions    = MathMin(g_MaxOpenPositions, 2);        // max 2 posisi
         g_DailyLossLimitPct   = MathMin(g_DailyLossLimitPct, 5.0);     // max 5% / hari
         g_MaxDrawdownPct      = MathMin(g_MaxDrawdownPct, 20.0);       // max DD 20%
         g_ATRVolMaxMult       = MathMin(g_ATRVolMaxMult, 2.5);         // filter volatil ketat
         g_SessionStartHour    = InpSessionStartHour;                   // misal 7
         g_SessionEndHour      = MathMin(g_SessionEndHour, 14);         // sampai 14
         break;

      case RISK_NORMAL:
         g_RiskPerTradePercent = MathMin(g_RiskPerTradePercent, 1.0);
         g_MaxOpenPositions    = MathMin(g_MaxOpenPositions, 3);
         g_DailyLossLimitPct   = MathMin(g_DailyLossLimitPct, 8.0);
         g_MaxDrawdownPct      = MathMin(g_MaxDrawdownPct, 25.0);
         g_ATRVolMaxMult       = InpATRVolMaxMultiplier; // default
         g_SessionStartHour    = InpSessionStartHour;
         g_SessionEndHour      = MathMax(g_SessionEndHour, 16);         // boleh sedikit lebih lama
         break;

      case RISK_AGGRESSIVE:
         g_RiskPerTradePercent = MathMin(g_RiskPerTradePercent, 2.0);
         g_MaxOpenPositions    = MathMin(MathMax(g_MaxOpenPositions, 3), 4);
         g_DailyLossLimitPct   = MathMin(MathMax(g_DailyLossLimitPct, 10.0), 12.0);
         g_MaxDrawdownPct      = MathMin(MathMax(g_MaxDrawdownPct, 30.0), 35.0);
         g_ATRVolMaxMult       = MathMax(g_ATRVolMaxMult, 4.0);         // lebih longgar
         g_SessionStartHour    = InpSessionStartHour;
         g_SessionEndHour      = MathMax(g_SessionEndHour, 20);         // boleh sampai malam
         break;
     }

   Print("Risk preset applied: ",
         (InpRiskProfile == RISK_SAFE ? "SAFE" :
         (InpRiskProfile == RISK_NORMAL ? "NORMAL" : "AGGRESSIVE")),
         ", Risk%=", DoubleToString(g_RiskPerTradePercent, 2),
         ", MaxPos=", g_MaxOpenPositions,
         ", DailyLoss%=", DoubleToString(g_DailyLossLimitPct, 2),
         ", MaxDD%=", DoubleToString(g_MaxDrawdownPct, 2));
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = GetSymbol();
   g_EquityHigh       = AccountInfoDouble(ACCOUNT_EQUITY);
   g_DailyStartEquity = g_EquityHigh;
   g_DailyDate        = TimeDay(TimeCurrent());

   // init FVG & swings
   g_LastBullishFVG.low  = 0;
   g_LastBullishFVG.high = 0;
   g_LastBullishFVG.bullish = true;
   g_LastBullishFVG.time_bar = 0;

   g_LastBearishFVG.low  = 0;
   g_LastBearishFVG.high = 0;
   g_LastBearishFVG.bullish = false;
   g_LastBearishFVG.time_bar = 0;

   g_LastSwingHighPrice = 0;
   g_LastSwingHighTime  = 0;
   g_LastSwingLowPrice  = 0;
   g_LastSwingLowTime   = 0;

   ApplyRiskPreset();

   g_ATRHandle_FVG      = iATR(g_symbol, InpFVGTF, InpATRPeriod);
   g_ATRHandle_FVG_Long = iATR(g_symbol, InpFVGTF, InpATRPeriod * 3);
   g_EMAHandle_HTF      = iMA(g_symbol, InpHTFTrendTF, InpBiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   Print("EA SMC FVG Guardian initialized on ", g_symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_ATRHandle_FVG != INVALID_HANDLE)
      IndicatorRelease(g_ATRHandle_FVG);
   if(g_ATRHandle_FVG_Long != INVALID_HANDLE)
      IndicatorRelease(g_ATRHandle_FVG_Long);
   if(g_EMAHandle_HTF != INVALID_HANDLE)
      IndicatorRelease(g_EMAHandle_HTF);

   Print("EA SMC FVG Guardian deinitialized. Reason = ", reason);
  }

//+------------------------------------------------------------------+
//| Helper: read indicator buffer value using CopyBuffer             |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle,int buffer,int shift)
  {
   if(handle == INVALID_HANDLE)
      return 0.0;

   double values[];
   if(CopyBuffer(handle, buffer, shift, 1, values) <= 0)
      return 0.0;

   return values[0];
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_symbol = GetSymbol();

   // Update equity tracking & daily reset
   UpdateEquityTracking();

   // Check risk protections
   if(IsDailyLossLimitHit())
     {
      Print("Daily loss limit / stop condition hit. Stop trading for today.");
      return;
     }

   if(IsMaxDDHit())
     {
      Print("Max drawdown hit.");
      if(InpCloseAllOnMaxDD)
         CloseAllPositions();
      return;
     }

   // Manage existing positions: BE, Trailing, Partial Close, dll
   ManageOpenPositions();

   bool newBar = UpdateSignalsOnNewBar();

   // Basic trade allowed check (session, spread, ATR, news)
   bool allowed = IsTradingAllowedNow();

   // Check jumlah posisi
   if(GetTotalOpenPositionsForSymbol(g_symbol, InpMagic) >= g_MaxOpenPositions)
      return;

   bool shouldCheckEntries = (!InpWaitForCandleClose || newBar);

   if(shouldCheckEntries && allowed)
      CheckAndExecuteEntries();
  }

//+------------------------------------------------------------------+
//| Update signals only when a new bar forms on FVG TF               |
//+------------------------------------------------------------------+
bool UpdateSignalsOnNewBar()
  {
   datetime bar_time = iTime(g_symbol, InpFVGTF, 0);
   if(bar_time == 0)
      return false;

   if(bar_time == g_lastSignalBarTime)
      return false;

   g_lastSignalBarTime = bar_time;

   // 1. Update trend HTF
   UpdateHTFTrend();

   // 2. Update SMC structure (swing + liquidity sweep)
   if(InpUseSMC)
      UpdateSMCStructure();

   // 3. Scan FVG zones
   if(InpUseFVG)
      ScanFVGZones();

   return true;
  }

//+------------------------------------------------------------------+
//| Check SMC/FVG setup and execute entries                          |
//+------------------------------------------------------------------+
void CheckAndExecuteEntries()
  {
   if(!(InpUseSMC && InpUseFVG))
      return;

   if(ExistBuySetup())
      TryOpenBuy();

   if(ExistSellSetup())
      TryOpenSell();
  }

//+------------------------------------------------------------------+
//| UpdateEquityTracking                                             |
//+------------------------------------------------------------------+
void UpdateEquityTracking()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > g_EquityHigh || g_EquityHigh == 0.0)
      g_EquityHigh = equity;

   int cur_date = TimeDay(TimeCurrent());

   if(cur_date != g_DailyDate)
     {
      g_DailyDate        = cur_date;
      g_DailyStartEquity = equity;
      Print("New day detected. Reset daily equity base: ", DoubleToString(equity, 2));
     }
  }

//+------------------------------------------------------------------+
//| Check Daily Loss Limit / Daily Profit Stop                       |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
  {
   if(g_DailyStartEquity <= 0.0)
      return false;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss_pct  = (g_DailyStartEquity - equity) / g_DailyStartEquity * 100.0;
   if(loss_pct >= g_DailyLossLimitPct)
      return true;

   if(InpStopAfterDailyProfit)
     {
      double profit_pct = (equity - g_DailyStartEquity) / g_DailyStartEquity * 100.0;
      if(profit_pct >= InpDailyProfitTargetPct)
        {
         Print("Daily profit target reached: ", DoubleToString(profit_pct, 2), "%");
         return true; // treat as stop trading
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Check Max Drawdown                                               |
//+------------------------------------------------------------------+
bool IsMaxDDHit()
  {
   if(g_MaxDrawdownPct <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_EquityHigh <= 0.0)
      return false;

   double dd_pct = (g_EquityHigh - equity) / g_EquityHigh * 100.0;
   if(dd_pct >= g_MaxDrawdownPct)
      return true;

   return false;
  }

//+------------------------------------------------------------------+
//| Close all positions for this symbol & magic                      |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i))
        {
         ulong  ticket = PositionGetInteger(POSITION_TICKET);
         string sym    = (string)PositionGetString(POSITION_SYMBOL);
         long   mgc    = PositionGetInteger(POSITION_MAGIC);

         if(mgc == (long)InpMagic && sym == g_symbol)
           {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double volume = PositionGetDouble(POSITION_VOLUME);
            if(volume <= 0.0)
               continue;

            if(type == POSITION_TYPE_BUY)
               trade.PositionClose(ticket);
            else if(type == POSITION_TYPE_SELL)
               trade.PositionClose(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Get total open positions for symbol & magic                      |
//+------------------------------------------------------------------+
int GetTotalOpenPositionsForSymbol(string symbol, ulong magic)
  {
   int count = 0;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
     {
      if(PositionGetTicket(i))
        {
         string sym = (string)PositionGetString(POSITION_SYMBOL);
         long   mgc = PositionGetInteger(POSITION_MAGIC);
         if(sym == symbol && mgc == (long)magic)
            count++;
        }
     }

   return count;
  }

//+------------------------------------------------------------------+
//| Trading allowed? (session, spread, ATR, news)                    |
//+------------------------------------------------------------------+
bool IsTradingAllowedNow()
  {
   int hour = TimeHour(TimeCurrent());

   // session
   if(InpUseSessionFilter)
     {
      if(hour < g_SessionStartHour || hour > g_SessionEndHour)
         return false;
     }

   if(InpUseAsiaNYFilter)
     {
      bool inAsia = (hour >= InpAsiaSessionStartHour && hour <= InpAsiaSessionEndHour);
      bool inNY   = (hour >= InpNYKillStartHour && hour <= InpNYKillEndHour);
      if(!(inAsia || inNY))
         return false;
     }

   // spread
   if(InpUseSpreadFilter)
     {
      int spread_points = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
      if(spread_points > InpMaxSpreadPoints)
         return false;
     }

   // ATR volatility filter
   if(InpUseATRVolFilter)
     {
      double atr = GetIndicatorValue(g_ATRHandle_FVG, 0, 0);
      if(atr > 0)
        {
         double atr_avg = GetIndicatorValue(g_ATRHandle_FVG_Long, 0, 0);
         if(atr_avg > 0 && atr > atr_avg * g_ATRVolMaxMult)
            return false;
        }
     }

   // News filter placeholder
   if(InpUseNewsFilter)
     {
      // TODO: implement news time check jika punya sumber news eksternal
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Update HTF Trend (EMA + price)                                   |
//+------------------------------------------------------------------+
void UpdateHTFTrend()
  {
   double ema   = GetIndicatorValue(g_EMAHandle_HTF, 0, 0);
   double price = iClose(g_symbol, InpHTFTrendTF, 0);

   if(ema == 0.0)
     {
      g_TrendBias = TREND_NONE;
      return;
     }

   if(price > ema)
      g_TrendBias = TREND_BULL;
   else if(price < ema)
      g_TrendBias = TREND_BEAR;
   else
      g_TrendBias = TREND_NONE;
  }

//+------------------------------------------------------------------+
//| Update SMC Structure: find last swing high/low with min distance |
//+------------------------------------------------------------------+
void UpdateSMCStructure()
  {
   int bars = iBars(g_symbol, InpSMCTF);
   if(bars < InpSMCSwingLookback + 5)
      return;

   double lastHighPrice = 0.0;
   datetime lastHighTime = 0;
   double lastLowPrice  = 0.0;
   datetime lastLowTime = 0;

   int maxLook = MathMin(InpSMCSwingLookback + 10, bars - 3);

   // Cari swing dari belakang: bar 2 s/d maxLook
   for(int i = 2; i <= maxLook; i++)
     {
      double h = iHigh(g_symbol, InpSMCTF, i);
      double l = iLow(g_symbol, InpSMCTF, i);
      double prevHigh = iHigh(g_symbol, InpSMCTF, i + 1);
      double nextHigh = iHigh(g_symbol, InpSMCTF, i - 1);
      double prevLow  = iLow(g_symbol, InpSMCTF, i + 1);
      double nextLow  = iLow(g_symbol, InpSMCTF, i - 1);

      bool isSwingHigh = (h > prevHigh && h > nextHigh);
      bool isSwingLow  = (l < prevLow && l < nextLow);

      if(isSwingHigh)
        {
         double refLow     = MathMin(prevLow, nextLow);
         double distPoints = (h - refLow) / _Point;
         if(distPoints >= InpSMCMinSwingSizePoints)
           {
            lastHighPrice = h;
            lastHighTime  = iTime(g_symbol, InpSMCTF, i);
           }
        }

      if(isSwingLow)
        {
         double refHigh    = MathMax(prevHigh, nextHigh);
         double distPoints = (refHigh - l) / _Point;
         if(distPoints >= InpSMCMinSwingSizePoints)
           {
            lastLowPrice = l;
            lastLowTime  = iTime(g_symbol, InpSMCTF, i);
           }
        }
     }

   if(lastHighPrice > 0.0)
     {
      g_LastSwingHighPrice = lastHighPrice;
      g_LastSwingHighTime  = lastHighTime;
     }

   if(lastLowPrice > 0.0)
     {
      g_LastSwingLowPrice = lastLowPrice;
      g_LastSwingLowTime  = lastLowTime;
     }
  }

//+------------------------------------------------------------------+
//| Scan FVG Zones (simple detection last bullish & bearish)         |
//+------------------------------------------------------------------+
void ScanFVGZones()
  {
   g_LastBullishFVG.low      = 0;
   g_LastBullishFVG.high     = 0;
   g_LastBullishFVG.bullish  = true;
   g_LastBullishFVG.time_bar = 0;

   g_LastBearishFVG.low      = 0;
   g_LastBearishFVG.high     = 0;
   g_LastBearishFVG.bullish  = false;
   g_LastBearishFVG.time_bar = 0;

   int bars = iBars(g_symbol, InpFVGTF);
   if(bars < 5)
      return;

   int lookback = MathMin(100, bars - 3);

   for(int i = 2; i <= lookback; i++)
     {
      double high_prev = iHigh(g_symbol, InpFVGTF, i + 1);
      double low_prev  = iLow(g_symbol, InpFVGTF, i + 1);
      double high_next = iHigh(g_symbol, InpFVGTF, i - 1);
      double low_next  = iLow(g_symbol, InpFVGTF, i - 1);

      // Bullish FVG: low_prev > high_next
      if(low_prev > high_next)
        {
         double points = (low_prev - high_next) / _Point;
         if(points >= InpMinFVGPoints && points <= InpMaxFVGPoints)
           {
            g_LastBullishFVG.low      = high_next;
            g_LastBullishFVG.high     = low_prev;
            g_LastBullishFVG.bullish  = true;
            g_LastBullishFVG.time_bar = iTime(g_symbol, InpFVGTF, i);
           }
        }

      // Bearish FVG: high_prev < low_next
      if(high_prev < low_next)
        {
         double points = (low_next - high_prev) / _Point;
         if(points >= InpMinFVGPoints && points <= InpMaxFVGPoints)
           {
            g_LastBearishFVG.low      = high_prev;
            g_LastBearishFVG.high     = low_next;
            g_LastBearishFVG.bullish  = false;
            g_LastBearishFVG.time_bar = iTime(g_symbol, InpFVGTF, i);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper: premium/discount zone (simple)                           |
//+------------------------------------------------------------------+
bool IsDiscountZonePrice(double price)
  {
   int bars = iBars(g_symbol, InpSMCTF);
   if(bars < InpSMCSwingLookback + 5)
      return true; // kalau data kurang, jangan blokir

   double hi = -DBL_MAX;
   double lo = DBL_MAX;

   int look = MathMin(InpSMCSwingLookback, bars - 1);

   for(int i = 0; i < look; i++)
     {
      double h = iHigh(g_symbol, InpSMCTF, i);
      double l = iLow(g_symbol, InpSMCTF, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
     }

   if(hi <= lo)
      return true;

   double mid = (hi + lo) / 2.0;

   // discount zone = bawah setengah
   if(price <= mid)
      return true;

   return false;
  }

bool IsPremiumZonePrice(double price)
  {
   int bars = iBars(g_symbol, InpSMCTF);
   if(bars < InpSMCSwingLookback + 5)
      return true;

   double hi = -DBL_MAX;
   double lo = DBL_MAX;

   int look = MathMin(InpSMCSwingLookback, bars - 1);

   for(int i = 0; i < look; i++)
     {
      double h = iHigh(g_symbol, InpSMCTF, i);
      double l = iLow(g_symbol, InpSMCTF, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
     }

   if(hi <= lo)
      return true;

   double mid = (hi + lo) / 2.0;

   // premium zone = atas setengah
   if(price >= mid)
      return true;

   return false;
  }

//+------------------------------------------------------------------+
//| Exist Buy Setup? (SMC+FVG)                                       |
//+------------------------------------------------------------------+
bool ExistBuySetup()
  {
   if(InpOnlyTradeWithTrend && g_TrendBias != TREND_BULL)
      return false;

   if(!InpUseFVG || g_LastBullishFVG.high <= 0.0 || g_LastBullishFVG.low <= 0.0)
      return false;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid <= 0)
      return false;

   if(bid < g_LastBullishFVG.low || bid > g_LastBullishFVG.high)
      return false;

   if(InpRequirePremiumDiscount && !IsDiscountZonePrice(bid))
      return false;

   if(InpUseSMC)
     {
      int smcBars = iBars(g_symbol, InpSMCTF);
      if(g_LastSwingLowPrice <= 0 || smcBars < 3)
         return false;

      double lowPrev   = iLow(g_symbol, InpSMCTF, 1);
      double closePrev = iClose(g_symbol, InpSMCTF, 1);
      bool sweptLow = (lowPrev < g_LastSwingLowPrice && closePrev > g_LastSwingLowPrice);
      if(!sweptLow)
         return false;

      double closeNow = iClose(g_symbol, InpSMCTF, 0);
      double highPrev = iHigh(g_symbol, InpSMCTF, 1);
      if(!(closeNow > highPrev))
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Exist Sell Setup? (SMC+FVG)                                      |
//+------------------------------------------------------------------+
bool ExistSellSetup()
  {
   if(InpOnlyTradeWithTrend && g_TrendBias != TREND_BEAR)
      return false;

   if(!InpUseFVG || g_LastBearishFVG.high <= 0.0 || g_LastBearishFVG.low <= 0.0)
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(ask <= 0)
      return false;

   if(ask < g_LastBearishFVG.low || ask > g_LastBearishFVG.high)
      return false;

   if(InpRequirePremiumDiscount && !IsPremiumZonePrice(ask))
      return false;

   if(InpUseSMC)
     {
      int smcBars = iBars(g_symbol, InpSMCTF);
      if(g_LastSwingHighPrice <= 0 || smcBars < 3)
         return false;

      double highPrev   = iHigh(g_symbol, InpSMCTF, 1);
      double closePrev  = iClose(g_symbol, InpSMCTF, 1);
      bool sweptHigh = (highPrev > g_LastSwingHighPrice && closePrev < g_LastSwingHighPrice);
      if(!sweptHigh)
         return false;

      double closeNow = iClose(g_symbol, InpSMCTF, 0);
      double lowPrev  = iLow(g_symbol, InpSMCTF, 1);
      if(!(closeNow < lowPrev))
         return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Calculate lot by risk                                            |
//+------------------------------------------------------------------+
double CalcLotByRisk(double sl_points)
  {
   if(sl_points <= 0)
      return InpFixedLot;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amt = equity * g_RiskPerTradePercent / 100.0;

   double tick_val  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_val <= 0 || tick_size <= 0)
      return InpFixedLot;

   double value_per_point_per_lot = tick_val * (_Point / tick_size);
   double lot = risk_amt / (sl_points * value_per_point_per_lot);

   double min_lot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lot_step) * lot_step;
   if(lot < min_lot)
      lot = min_lot;
   if(lot > max_lot)
      lot = max_lot;

   return lot;
  }

//+------------------------------------------------------------------+
//| Try Open Buy                                                     |
//+------------------------------------------------------------------+
void TryOpenBuy()
  {
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return;

   double baseSL = g_LastBullishFVG.low;

   if(InpUseStructureSL && g_LastSwingLowPrice > 0)
      baseSL = MathMin(baseSL, g_LastSwingLowPrice);

   double sl_price = baseSL - InpSLMinPoints * _Point;
   double sl_points = (bid - sl_price) / _Point;

   if(sl_points < InpSLMinPoints || sl_points > InpSLMaxPoints)
      return;

   double lot = InpFixedLot;
   if(!InpUseFixedLot)
      lot = CalcLotByRisk(sl_points);

   double tp_points = sl_points * InpRRRatio;
   double tp_price  = bid + tp_points * _Point;

   trade.SetExpertMagicNumber(InpMagic);
   bool result = trade.Buy(lot, g_symbol, ask, sl_price, tp_price, "SMC_FVG_Buy");

   if(result)
      Print("Buy opened: lot=", lot, " sl=", DoubleToString(sl_price, 2), " tp=", DoubleToString(tp_price, 2));
   else
      Print("Buy open failed. Error: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Try Open Sell                                                    |
//+------------------------------------------------------------------+
void TryOpenSell()
  {
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return;

   double baseSL = g_LastBearishFVG.high;

   if(InpUseStructureSL && g_LastSwingHighPrice > 0)
      baseSL = MathMax(baseSL, g_LastSwingHighPrice);

   double sl_price = baseSL + InpSLMinPoints * _Point;
   double sl_points = (sl_price - ask) / _Point;

   if(sl_points < InpSLMinPoints || sl_points > InpSLMaxPoints)
      return;

   double lot = InpFixedLot;
   if(!InpUseFixedLot)
      lot = CalcLotByRisk(sl_points);

   double tp_points = sl_points * InpRRRatio;
   double tp_price  = ask - tp_points * _Point;

   trade.SetExpertMagicNumber(InpMagic);
   bool result = trade.Sell(lot, g_symbol, bid, sl_price, tp_price, "SMC_FVG_Sell");

   if(result)
      Print("Sell opened: lot=", lot, " sl=", DoubleToString(sl_price, 2), " tp=", DoubleToString(tp_price, 2));
   else
      Print("Sell open failed. Error: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Manage open positions (BE, trailing, partial)                    |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      if(!PositionGetTicket(i))
         continue;

      string sym  = (string)PositionGetString(POSITION_SYMBOL);
      long   mgc  = PositionGetInteger(POSITION_MAGIC);
      if(sym != g_symbol || mgc != (long)InpMagic)
         continue;

      ulong ticket      = PositionGetInteger(POSITION_TICKET);
      double volume     = PositionGetDouble(POSITION_VOLUME);
      double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl         = PositionGetDouble(POSITION_SL);
      double tp         = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double sl_points = 0.0;
      if(type == POSITION_TYPE_BUY && sl > 0)
         sl_points = (price_open - sl) / _Point;
      else if(type == POSITION_TYPE_SELL && sl > 0)
         sl_points = (sl - price_open) / _Point;

      if(sl_points <= 0)
         continue;

      double price_now = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(g_symbol, SYMBOL_BID)
                                                    : SymbolInfoDouble(g_symbol, SYMBOL_ASK));
      if(price_now <= 0)
         continue;

      double profit_points = 0.0;
      if(type == POSITION_TYPE_BUY)
         profit_points = (price_now - price_open) / _Point;
      else
         profit_points = (price_open - price_now) / _Point;

      double rr_now = profit_points / sl_points;

      // Break Even
      if(InpUseBreakEven && rr_now >= InpBETriggerRR && sl > 0)
        {
         double new_sl = price_open + (type == POSITION_TYPE_BUY ? InpBEOffsetPoints * _Point
                                                                 : -InpBEOffsetPoints * _Point);
         if(type == POSITION_TYPE_BUY && new_sl < price_now && new_sl > sl)
            trade.PositionModify(ticket, new_sl, tp);
         else if(type == POSITION_TYPE_SELL && new_sl > price_now && new_sl < sl)
            trade.PositionModify(ticket, new_sl, tp);
        }

      // Adaptive trailing ala Quantum Queen
      if(InpUseAdaptiveTrailing)
        {
         double atr = GetIndicatorValue(g_ATRHandle_FVG, 0, 0);
         if(atr > 0)
           {
            double trailMult = 0.0;
            if(rr_now >= InpAdaptiveStrongRR)
               trailMult = InpATRFastMultiplier;
            else if(rr_now >= InpAdaptiveStartRR)
               trailMult = InpATRSlowMultiplier;

            if(trailMult > 0.0)
              {
               double trail_dist = atr * trailMult;
               double new_sl = 0.0;

               if(type == POSITION_TYPE_BUY)
                 {
                  new_sl = price_now - trail_dist;
                  if((sl <= 0 || new_sl > sl) && new_sl < price_now)
                     trade.PositionModify(ticket, new_sl, tp);
                 }
               else if(type == POSITION_TYPE_SELL)
                 {
                  new_sl = price_now + trail_dist;
                  if((sl <= 0 || new_sl < sl) && new_sl > price_now)
                     trade.PositionModify(ticket, new_sl, tp);
                 }
              }
           }
        }
      else if(InpUseATRTrailing && rr_now >= InpATRTrailTriggerRR)
        {
         double atr = GetIndicatorValue(g_ATRHandle_FVG, 0, 0);
         if(atr > 0)
           {
            double trail_dist = atr * InpATRTrailMultiplier;
            double new_sl = 0.0;

            if(type == POSITION_TYPE_BUY)
              {
               new_sl = price_now - trail_dist;
               if(new_sl > sl && new_sl < price_now)
                  trade.PositionModify(ticket, new_sl, tp);
              }
            else if(type == POSITION_TYPE_SELL)
              {
               new_sl = price_now + trail_dist;
               if(new_sl < sl && new_sl > price_now)
                  trade.PositionModify(ticket, new_sl, tp);
              }
           }
        }

      // Partial close (optional)
      if(InpUsePartialClose && rr_now >= InpPartialCloseAtRR)
        {
         double min_lot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
         if(volume > min_lot * 1.5)
           {
            double close_lot = volume * InpPartialClosePercent / 100.0;
            close_lot = MathMax(close_lot, min_lot);

            bool closed = trade.PositionClosePartial(ticket, close_lot);
            if(closed)
               Print("Partial close done on ticket ", ticket, " lot=", close_lot);
           }
        }
     }
  }

//+------------------------------------------------------------------+
