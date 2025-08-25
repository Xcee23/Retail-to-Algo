//+------------------------------------------------------------------+
//|                           SMC_EA_v2.mq5 (v1.1 of your file)      |
//|             SMC Volatility-Adaptive EA (Smart Money Concepts)    |
//|                     Copyright 2025, Jules the AI Engineer        |
//|                                   (No external link)             |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2025, Jules the AI Engineer"
#property link        ""
#property version     "1.10"
#property description "A volatility-adaptive trading system based on Smart Money Concepts."

#include <Trade/Trade.mqh>

//=====================================================================
// Enums for New Strategy Inputs
//=====================================================================
enum ENUM_FIB_CONFIRMATION
  {
   CONF_ENGULFING,    // Engulfing Candle
   CONF_PIN_BAR,      // Pin Bar / Rejection Wick
   CONF_MINOR_BOS     // Minor Break of Structure
  };

enum ENUM_SL_METHOD
  {
   SL_CONSERVATIVE,   // Place SL beyond the swing extreme
   SL_AGGRESSIVE      // Place SL just outside the Fib zone
  };

//=====================================================================
// Inputs
//=====================================================================
input group "Market Regime Filter"
input ENUM_TIMEFRAMES HTF_Timeframe            = PERIOD_H4; // Higher timeframe for trend
input int           HTF_SmaFast_Period         = 20;        // Fast SMA on HTF
input int           HTF_SmaMedium_Period       = 50;        // Medium SMA on HTF
input int           HTF_SmaSlow_Period         = 200;       // Slow SMA on HTF
input int           ADX_Period                 = 14;        // ADX Period
input double        ADX_Threshold              = 25.0;      // ADX value to confirm trend

input group "Entry & SMC Parameters"
input int           ATR_Period_Entry           = 14;        // ATR Period for entries & SL
input double        BOS_ATR_Multiplier         = 1.0;       // ATR buffer for BOS confirmation
input int           BOS_MinConsecutiveCloses   = 1;         // # of closes beyond swing for BOS
input double        OB_Body_ATR_Multiplier     = 1.0;       // OB body size filter (x ATR)
input int           Swing_Lookaround_Bars      = 10;        // Bars left & right for swing
input double        FVG_Min_ATR_Ratio          = 0.5;       // Minimum FVG gap size in ATRs

input group "Trading Session"
input int           Session_Start_Hour         = 8;         // e.g., 8 for 8:00
input int           Session_End_Hour           = 16;        // e.g., 16 for 16:00
input int           Session_Timezone_GMT_Offset= -5;        // Fixed offset (NY EST = -5)

input group "Risk & Trade Management"
input int           Pending_Order_Expiry_Bars  = 10;        // Bars a pending order stays active
input double        Risk_Per_Trade_Percent     = 1.0;       // Percent of equity risked per trade
input double        Take_Profit_RR_Ratio       = 2.0;       // TP in R multiples
input uint          Expert_Magic               = 20250825;  // Magic number for this EA
input int           Max_Spread_Points          = 50;        // 0 to disable

input group "Trailing Stop"
input bool          Use_Trailing_Stop          = true;      // Enable/Disable ATR trailing stop
input int           TS_ATR_Period              = 14;        // ATR period for the trailing stop
input double        TS_ATR_Multiplier          = 3.0;       // ATR multiplier for trailing

input group "Visual & Chart Settings"
input bool          Show_Visuals               = true;      // Enable/Disable on-chart visuals
input color         Bullish_Zone_Color         = clrLightBlue;
input color         Bearish_Zone_Color         = clrLightPink;
input color         BOS_Line_Color             = clrOrange;

input group "Fibonacci Strategy Settings"
input bool          EnableFibStrategy          = true;      // --- ENABLE/DISABLE FIB STRATEGY ---
input double        Fib_Level_1                = 75.0;      // Entry Zone Start %
input double        Fib_Level_2                = 79.0;      // Entry Zone End %
input ENUM_FIB_CONFIRMATION Confirmation_Type  = CONF_ENGULFING; // Entry confirmation signal
input ENUM_SL_METHOD SL_Method                 = SL_CONSERVATIVE; // Stop Loss placement method
input bool          Use_Partial_TP             = true;      // Use TP1 and then trail?
input int           Fib_Minor_BOS_Lookaround   = 5;         // Lookaround bars for Minor BOS
input int           Fib_Lookback_Period        = 300;       // Bars to look back for major swings

//=====================================================================
// Globals
//=====================================================================
// Indicator Handles
int h_HTF_SmaFast;
int h_HTF_SmaMedium;
int h_HTF_SmaSlow;
int h_HTF_Adx;
int h_ATR_Entry;
int h_TS_Atr; // For trailing stop

CTrade trade; // trade object

//=====================================================================
// Utils / Guards
//=====================================================================
bool isNewBar()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LAST_BAR_TIME);
   if(last_bar_time != current_bar_time)
   {
      last_bar_time = current_bar_time;
      return true;
   }
   return false;
}

bool SpreadOkay()
{
   if(Max_Spread_Points <= 0) return true;
   long spr = (long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spr <= Max_Spread_Points);
}

// Fixed-offset time window (no DST handling)
bool checkTimeFilters()
{
   datetime utc = TimeGMT(); // UTC now
   int offset_sec = Session_Timezone_GMT_Offset * 3600;
   MqlDateTime tt;
   TimeToStruct(utc + offset_sec, tt);
   if(tt.hour >= Session_Start_Hour && tt.hour < Session_End_Hour) return true;
   return false;
}

//=====================================================================
// Regime detection
//=====================================================================
enum ENUM_MARKET_REGIME { BULLISH_TREND, BEARISH_TREND, SIDEWAYS_RANGE };

ENUM_MARKET_REGIME checkMarketRegime()
{
   double sma_fast_buffer[], sma_medium_buffer[], sma_slow_buffer[], adx_buffer[];
   ArraySetAsSeries(sma_fast_buffer, true);
   ArraySetAsSeries(sma_medium_buffer, true);
   ArraySetAsSeries(sma_slow_buffer, true);
   ArraySetAsSeries(adx_buffer, true);

   if(CopyBuffer(h_HTF_SmaFast,  0, 0, 2, sma_fast_buffer)   < 2) return SIDEWAYS_RANGE;
   if(CopyBuffer(h_HTF_SmaMedium,0, 0, 2, sma_medium_buffer) < 2) return SIDEWAYS_RANGE;
   if(CopyBuffer(h_HTF_SmaSlow,  0, 0, 2, sma_slow_buffer)   < 2) return SIDEWAYS_RANGE;
   if(CopyBuffer(h_HTF_Adx,      0, 0, 2, adx_buffer)        < 2) return SIDEWAYS_RANGE;

   double fast_sma = sma_fast_buffer[1];
   double medium_sma = sma_medium_buffer[1];
   double slow_sma = sma_slow_buffer[1];
   double adx = adx_buffer[1];

   if(fast_sma > medium_sma && medium_sma > slow_sma && adx > ADX_Threshold)
      return BULLISH_TREND;
   if(fast_sma < medium_sma && medium_sma < slow_sma && adx > ADX_Threshold)
      return BEARISH_TREND;
   return SIDEWAYS_RANGE;
}

//=====================================================================
// Swing detection (backward search, no look-ahead)
//=====================================================================
int findLastSwingHigh(const int start_bar, const int lookaround)
{
   int total = Bars(_Symbol, _Period);
   for(int i = start_bar + lookaround; i < total - lookaround; i++)
   {
      double ch = iHigh(_Symbol, _Period, i);
      bool swing = true;
      for(int j = 1; j <= lookaround; j++)
      {
         if(iHigh(_Symbol, _Period, i - j) > ch || iHigh(_Symbol, _Period, i + j) > ch) { swing = false; break; }
      }
      if(swing) return i;
   }
   return -1;
}

int findLastSwingLow(const int start_bar, const int lookaround)
{
   int total = Bars(_Symbol, _Period);
   for(int i = start_bar + lookaround; i < total - lookaround; i++)
   {
      double cl = iLow(_Symbol, _Period, i);
      bool swing = true;
      for(int j = 1; j <= lookaround; j++)
      {
         if(iLow(_Symbol, _Period, i - j) < cl || iLow(_Symbol, _Period, i + j) < cl) { swing = false; break; }
      }
      if(swing) return i;
   }
   return -1;
}

//=====================================================================
// SMC primitives (BOS / FVG / OB) & Confirmation Patterns
//=====================================================================
struct TradeSignal { bool isValid; ENUM_ORDER_TYPE order_type; double entry_price; double sl_price; double tp_price; };
struct BOS_Info { bool detected; int bar_index; };
struct FVG_Info { bool detected; double top; double bottom; };
struct OB_Info  { bool detected; double top; double bottom; };

// Refactored to accept lookaround parameter
BOS_Info detectBOS(const int start_bar, const ENUM_MARKET_REGIME direction, const int lookaround)
{
   BOS_Info res = {false, -1};
   double atr_value_buffer[];
   if(CopyBuffer(h_ATR_Entry, 0, start_bar, 1, atr_value_buffer) < 1) return res;
   double atr_value = atr_value_buffer[0];

   if(MathAbs(iOpen(_Symbol, _Period, start_bar) - iClose(_Symbol, _Period, start_bar)) < atr_value)
      return res;

   double buf = atr_value * BOS_ATR_Multiplier;
   int need_closes = MathMax(1, BOS_MinConsecutiveCloses);

   if(direction == BULLISH_TREND)
   {
      int swing_high_idx = findLastSwingHigh(start_bar + 1, lookaround);
      if(swing_high_idx != -1)
      {
         double swing = iHigh(_Symbol, _Period, swing_high_idx);
         int closes_ok = 0;
         for(int k = start_bar; k >= start_bar - 3 && k >= 0; --k)
         {
            if(iClose(_Symbol, _Period, k) > (swing + buf)) closes_ok++; else break;
         }
         if(closes_ok >= need_closes) { res.detected = true; res.bar_index = start_bar; return res; }
      }
   }
   else if(direction == BEARISH_TREND)
   {
      int swing_low_idx = findLastSwingLow(start_bar + 1, lookaround);
      if(swing_low_idx != -1)
      {
         double swing = iLow(_Symbol, _Period, swing_low_idx);
         int closes_ok = 0;
         for(int k = start_bar; k >= start_bar - 3 && k >= 0; --k)
         {
            if(iClose(_Symbol, _Period, k) < (swing - buf)) closes_ok++; else break;
         }
         if(closes_ok >= need_closes) { res.detected = true; res.bar_index = start_bar; return res; }
      }
   }
   return res;
}

BOS_Info detectMinorBOS(const int start_bar, const ENUM_MARKET_REGIME direction)
{
   return detectBOS(start_bar, direction, Fib_Minor_BOS_Lookaround);
}

bool isEngulfing(const int bar_idx, const ENUM_MARKET_REGIME direction)
{
   double body_curr = MathAbs(iOpen(_Symbol, _Period, bar_idx) - iClose(_Symbol, _Period, bar_idx));
   double body_prev = MathAbs(iOpen(_Symbol, _Period, bar_idx + 1) - iClose(_Symbol, _Period, bar_idx + 1));

   if(direction == BULLISH_TREND)
   {
      bool is_bullish_candle = iClose(_Symbol, _Period, bar_idx) > iOpen(_Symbol, _Period, bar_idx);
      bool is_prev_bearish = iClose(_Symbol, _Period, bar_idx + 1) < iOpen(_Symbol, _Period, bar_idx + 1);
      return is_bullish_candle && is_prev_bearish && body_curr > body_prev;
   }
   else // Bearish
   {
      bool is_bearish_candle = iClose(_Symbol, _Period, bar_idx) < iOpen(_Symbol, _Period, bar_idx);
      bool is_prev_bullish = iClose(_Symbol, _Period, bar_idx + 1) > iOpen(_Symbol, _Period, bar_idx + 1);
      return is_bearish_candle && is_prev_bullish && body_curr > body_prev;
   }
}

bool isPinBar(const int bar_idx, const ENUM_MARKET_REGIME direction)
{
   double open = iOpen(_Symbol, _Period, bar_idx);
   double high = iHigh(_Symbol, _Period, bar_idx);
   double low = iLow(_Symbol, _Period, bar_idx);
   double close = iClose(_Symbol, _Period, bar_idx);

   double body = MathAbs(open - close);
   double range = high - low;
   if(range < _Point * 5 || body < _Point) return false; // Avoid division by zero and dojis

   if(direction == BULLISH_TREND)
   {
      double lower_wick = MathMin(open, close) - low;
      return (lower_wick > body * 2.0) && (body < range * 0.33);
   }
   else // Bearish
   {
      double upper_wick = high - MathMax(open, close);
      return (upper_wick > body * 2.0) && (body < range * 0.33);
   }
}

FVG_Info detectFVG(const int start_bar, const ENUM_MARKET_REGIME direction)
{
   FVG_Info res = {false, 0.0, 0.0};
   if(start_bar < 2) return res;

   double atr_value_buffer[];
   if(CopyBuffer(h_ATR_Entry, 0, start_bar, 1, atr_value_buffer) < 1) return res;
   double min_gap_size = atr_value_buffer[0] * FVG_Min_ATR_Ratio;

   if(direction == BULLISH_TREND)
   {
      double gap_top = iLow(_Symbol, _Period, start_bar);
      double gap_bottom = iHigh(_Symbol, _Period, start_bar + 2);
      if(gap_top > gap_bottom && (gap_top - gap_bottom) > min_gap_size)
      { res.detected = true; res.top = gap_top; res.bottom = gap_bottom; }
   }
   else if(direction == BEARISH_TREND)
   {
      double gap_top = iLow(_Symbol, _Period, start_bar + 2);
      double gap_bottom = iHigh(_Symbol, _Period, start_bar);
      if(gap_top > gap_bottom && (gap_top - gap_bottom) > min_gap_size)
      { res.detected = true; res.top = gap_top; res.bottom = gap_bottom; }
   }
   return res;
}

OB_Info detectOrderBlock(const int bos_bar_index, const ENUM_MARKET_REGIME direction)
{
   OB_Info res = {false, 0.0, 0.0};
   // Search the last opposite candle prior to the impulse that broke structure
   for(int i = bos_bar_index + 1; i < bos_bar_index + 50; i++)
   {
      double o = iOpen(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      bool opp = (direction == BULLISH_TREND && c < o) || (direction == BEARISH_TREND && c > o);
      if(!opp) continue;

      double atr_value_buffer[];
      if(CopyBuffer(h_ATR_Entry, 0, i, 1, atr_value_buffer) < 1) continue;
      double atrv = atr_value_buffer[0];
      if(MathAbs(o - c) <= atrv * OB_Body_ATR_Multiplier) continue;

      res.detected = true;
      res.top = iHigh(_Symbol, _Period, i);
      res.bottom = iLow(_Symbol, _Period, i);
      return res; // first valid OB
   }
   return res;
}

//--- Finds the last relevant order block for the Fib strategy
OB_Info findLastOrderBlock(const int start_bar, const int lookback, const ENUM_MARKET_REGIME direction)
{
   OB_Info res = {false, 0, 0};
   for(int i = start_bar; i < start_bar + lookback; i++)
   {
      double o = iOpen(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      bool is_opposite = (direction == BULLISH_TREND && c < o) || (direction == BEARISH_TREND && c > o);
      if(is_opposite)
      {
         double atr_val_buf[];
         if(CopyBuffer(h_ATR_Entry, 0, i, 1, atr_val_buf) < 1) continue;
         if(MathAbs(o-c) > atr_val_buf[0] * OB_Body_ATR_Multiplier)
         {
            res.detected = true;
            res.top = iHigh(_Symbol, _Period, i);
            res.bottom = iLow(_Symbol, _Period, i);
            return res;
         }
      }
   }
   return res;
}

//--- Main Logic for the new Fibonacci Strategy
TradeSignal CheckFibonacciStrategy(const int start_bar)
{
    TradeSignal signal = {false};

    // 1. Find major swings
    FibSwings swings = findRecentMajorSwings(start_bar, Fib_Lookback_Period);
    if(!swings.isValid) return signal;

    // 2. Determine trend direction from swings
    ENUM_MARKET_REGIME direction = (swings.high_time > swings.low_time) ? BEARISH_TREND : BULLISH_TREND;

    // 3. Calculate Fib levels for the entry zone
    double range = MathAbs(swings.high_price - swings.low_price);
    double fib_zone_top = (direction == BEARISH_TREND) ? swings.low_price + range * (Fib_Level_2 / 100.0) : swings.high_price - range * (Fib_Level_1 / 100.0);
    double fib_zone_bottom = (direction == BEARISH_TREND) ? swings.low_price + range * (Fib_Level_1 / 100.0) : swings.high_price - range * (Fib_Level_2 / 100.0);

    // 4. Find an overlapping Order Block
    OB_Info ob = findLastOrderBlock(start_bar, 100, direction); // Look back 100 bars for an OB
    if(!ob.detected || ob.bottom > fib_zone_top || ob.top < fib_zone_bottom) return signal;

    // 5. If we have a valid zone, draw it and check for entry
    string fib_name = "SMC_EA_FIB_" + (string)swings.high_time;
    DrawFibonacciLevels(fib_name, swings);

    // 6. Check if price is in the zone
    double current_high = iHigh(_Symbol, _Period, start_bar);
    double current_low = iLow(_Symbol, _Period, start_bar);
    bool in_zone = (direction == BEARISH_TREND && current_high >= fib_zone_bottom) || (direction == BULLISH_TREND && current_low <= fib_zone_top);
    if(!in_zone) return signal;

    // 7. Check for confirmation signal
    bool confirmed = false;
    switch(Confirmation_Type)
    {
        case CONF_ENGULFING: confirmed = isEngulfing(start_bar, direction); break;
        case CONF_PIN_BAR: confirmed = isPinBar(start_bar, direction); break;
        case CONF_MINOR_BOS: confirmed = detectMinorBOS(start_bar, direction).detected; break;
    }
    if(!confirmed) return signal;

    // 8. If all conditions met, populate the trade signal
    signal.isValid = true;
    signal.order_type = (direction == BULLISH_TREND) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    signal.entry_price = SymbolInfoDouble(_Symbol, (direction == BULLISH_TREND) ? SYMBOL_ASK : SYMBOL_BID);

    if(SL_Method == SL_CONSERVATIVE)
      signal.sl_price = (direction == BULLISH_TREND) ? swings.low_price : swings.high_price;
    else // Aggressive
      signal.sl_price = (direction == BULLISH_TREND) ? fib_zone_bottom : fib_zone_top;

    signal.tp_price = (direction == BULLISH_TREND) ? swings.high_price : swings.low_price;

    return signal;
}
//=====================================================================
// Visuals
//=====================================================================
// Struct to hold swing points for Fibonacci
struct FibSwings
  {
   bool     isValid;
   datetime high_time;
   double   high_price;
   datetime low_time;
   double   low_price;
  };

// --- Finds the most recent major swing high and low for Fibonacci
FibSwings findRecentMajorSwings(const int start_bar, const int lookback_period)
  {
   FibSwings res = {false};
   int high_idx = iHighest(_Symbol, _Period, MODE_HIGH, lookback_period, start_bar);
   int low_idx = iLowest(_Symbol, _Period, MODE_LOW, lookback_period, start_bar);

   if(high_idx != -1 && low_idx != -1 && high_idx != low_idx)
     {
      res.isValid = true;
      res.high_time = iTime(_Symbol, _Period, high_idx);
      res.high_price = iHigh(_Symbol, _Period, high_idx);
      res.low_time = iTime(_Symbol, _Period, low_idx);
      res.low_price = iLow(_Symbol, _Period, low_idx);
     }
   return res;
  }

// --- Draws Fibonacci levels on the chart
void DrawFibonacciLevels(string name, FibSwings swings)
  {
   if(IsStopped() || !Show_Visuals) return;
   if(ObjectFind(0, name) > -1) ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_FIBO, 0, swings.high_time, swings.high_price, swings.low_time, swings.low_price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrGoldenrod);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetBool(0, name, OBJPROP_SELECTABLE, false);

   // Customize levels
   int levels = 4;
   ObjectSetInteger(0, name, OBJPROP_LEVELS, levels);
   ObjectSetDouble(0, name, OBJPROP_LEVELVALUE, 0, 0.0);
   ObjectSetDouble(0, name, OBJPROP_LEVELVALUE, 1, 1.0);
   ObjectSetDouble(0, name, OBJPROP_LEVELVALUE, 2, Fib_Level_1 / 100.0);
   ObjectSetDouble(0, name, OBJPROP_LEVELVALUE, 3, Fib_Level_2 / 100.0);
  }

void DrawRectangle(const string name, const datetime time1, const double price1, const datetime time2, const double price2, const color rect_color, const string label_text)
{
   if(IsStopped() || !Show_Visuals) return;
   if(ObjectFind(0, name) > -1) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, time1, price1, time2, price2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, rect_color);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetBool(0, name, OBJPROP_FILL, true);
   ObjectSetBool(0, name, OBJPROP_BACK, true);

   string label_name = name + "_label";
   if(ObjectFind(0, label_name) > -1) ObjectDelete(0, label_name);
   ObjectCreate(0, label_name, OBJ_TEXT, 0, time1, price1);
   ObjectSetString(0, label_name, OBJPROP_TEXT, label_text);
   ObjectSetInteger(0, label_name, OBJPROP_COLOR, clrDimGray); // contrast for readability
   ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, label_name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
}

void DrawLine(const string name, const datetime time1, const double price1, const datetime time2, const double price2, const color line_color)
{
   if(IsStopped() || !Show_Visuals) return;
   if(ObjectFind(0, name) > -1) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, time1, price1, time2, price2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, line_color);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

void CleanupChartObjects(const int max_age_bars)
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   for(int i = ObjectsTotal(0) - 1; i >= 0; --i)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "SMC_EA_") != 0) continue;
      datetime obj_time = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 0);
      int age_bars = iBarShift(_Symbol, _Period, obj_time, false);
      if(age_bars > max_age_bars) ObjectDelete(0, name);
   }
}

//=====================================================================
// Position sizing
//=====================================================================
double NormalizeLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   int    vd   = (int)SymbolInfoInteger(_Symbol, SYMBOL_VOLUME_DIGITS);

   if(step > 0.0) lots = MathFloor(lots/step) * step;
   lots = NormalizeDouble(lots, vd);
   lots = MathMax(minv, MathMin(maxv, lots));
   return lots;
}

double CalculateVolume(double entry_price, double sl_price, bool is_buy)
{
   if(sl_price == entry_price) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * (Risk_Per_Trade_Percent / 100.0);

   double loss_per_lot = 0.0;
   ENUM_ORDER_TYPE sim = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(sim, _Symbol, 1.0, entry_price, sl_price, loss_per_lot))
   {
      Print("Error calculating P/L: ", GetLastError());
      return 0.0;
   }
   if(loss_per_lot >= 0.0) return 0.0; // should be a loss for SL

   double lots = risk_amount / MathAbs(loss_per_lot);

   // Margin sanity
   double px = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double margin = 0.0;
   if(OrderCalcMargin(sim, _Symbol, lots, px, margin))
   {
      double free_margin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
      if(margin > free_margin && margin > 0.0) lots *= (free_margin / margin) * 0.95; // leave buffer
   }

   return NormalizeLots(lots);
}

//=====================================================================
// Order helpers
//=====================================================================
bool HasOurPendingForSymbol()
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      if(!OrderSelect(i, SELECT_BY_POS)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)Expert_Magic) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT) return true;
   }
   return false;
}

//=====================================================================
// Lifecycle
//=====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber((long)Expert_Magic);

   // HTF indicators
   h_HTF_SmaFast   = iSMA(_Symbol, HTF_Timeframe, HTF_SmaFast_Period,   0, MODE_SMA, PRICE_CLOSE);
   if(h_HTF_SmaFast == INVALID_HANDLE) { Print("Error creating HTF Fast SMA");   return INIT_FAILED; }
   h_HTF_SmaMedium = iSMA(_Symbol, HTF_Timeframe, HTF_SmaMedium_Period, 0, MODE_SMA, PRICE_CLOSE);
   if(h_HTF_SmaMedium == INVALID_HANDLE) { Print("Error creating HTF Medium SMA"); return INIT_FAILED; }
   h_HTF_SmaSlow   = iSMA(_Symbol, HTF_Timeframe, HTF_SmaSlow_Period,   0, MODE_SMA, PRICE_CLOSE);
   if(h_HTF_SmaSlow == INVALID_HANDLE) { Print("Error creating HTF Slow SMA");   return INIT_FAILED; }
   h_HTF_Adx       = iADX(_Symbol, HTF_Timeframe, ADX_Period);
   if(h_HTF_Adx == INVALID_HANDLE)     { Print("Error creating HTF ADX");        return INIT_FAILED; }

   // Current TF indicators
   h_ATR_Entry = iATR(_Symbol, _Period, ATR_Period_Entry);
   if(h_ATR_Entry == INVALID_HANDLE)   { Print("Error creating Entry ATR");      return INIT_FAILED; }

   if(Use_Trailing_Stop)
   {
      h_TS_Atr = iATR(_Symbol, _Period, TS_ATR_Period);
      if(h_TS_Atr == INVALID_HANDLE) { Print("Error creating Trailing ATR");     return INIT_FAILED; }
   }

   Print("SMC Volatility Adaptive EA v1.1 initialized successfully.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Optional: clean objects or detach indicators; left as-is to keep visuals
}

//=====================================================================
// OnTick
//=====================================================================
void OnTick()
{
   if(!isNewBar()) return;
   CleanupChartObjects(300);
   if(!SpreadOkay()) return;

   // --- POSITION MANAGEMENT ---
   if(PositionSelect(_Symbol))
   {
      // ATR Trailing Stop Logic
      if(Use_Trailing_Stop)
      {
         double atr_buffer[];
         if(CopyBuffer(h_TS_Atr, 0, 0, 2, atr_buffer) > 0)
         {
            double dist = atr_buffer[1] * TS_ATR_Multiplier;
            double curr_sl = PositionGetDouble(POSITION_SL);
            double pos_open = PositionGetDouble(POSITION_PRICE_OPEN);
            double new_sl = 0.0;
            long ptype = PositionGetInteger(POSITION_TYPE);
            if(ptype == POSITION_TYPE_BUY)
            {
               new_sl = SymbolInfoDouble(_Symbol, SYMBOL_BID) - dist;
               if((new_sl > curr_sl) && (new_sl > pos_open)) trade.PositionModify(_Symbol, new_sl, PositionGetDouble(POSITION_TP));
            }
            else if(ptype == POSITION_TYPE_SELL)
            {
               new_sl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + dist;
               if((new_sl < curr_sl) && (new_sl < pos_open)) trade.PositionModify(_Symbol, new_sl, PositionGetDouble(POSITION_TP));
            }
         }
      }
      return; // In a trade, so don't scan for new setups
   }

   // --- PENDING ORDER MANAGEMENT ---
   if(OrdersTotal() > 0)
   {
      for(int i = OrdersTotal() - 1; i >= 0; --i)
      {
         if(!OrderSelect(i, SELECT_BY_POS)) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)Expert_Magic) continue;

         // Expire old pending orders
         if((TimeCurrent() - (datetime)OrderGetInteger(ORDER_TIME_SETUP)) > (Pending_Order_Expiry_Bars * PeriodSeconds()))
         {
            trade.OrderDelete((ulong)OrderGetInteger(ORDER_TICKET));
         }
         // If we have any live pending order for this symbol, don't create new ones
         return;
      }
   }

   // --- NEW SETUP SCANNING ---
   if(!checkTimeFilters()) return;

   // --- STRATEGY 1: Fibonacci Retracement Strategy ---
   if(EnableFibStrategy)
   {
      TradeSignal fib_signal = CheckFibonacciStrategy(1);
      if(fib_signal.isValid)
      {
         bool is_buy = (fib_signal.order_type == ORDER_TYPE_BUY);
         // For partial TP, open two trades at half volume each
         if(Use_Partial_TP)
         {
            double volume = CalculateVolume(fib_signal.entry_price, fib_signal.sl_price, is_buy) / 2.0;
            if(volume > 0)
            {
               // Trade 1: With TP1
               trade.TradeOpen(0, fib_signal.order_type, volume, _Symbol, fib_signal.entry_price, fib_signal.sl_price, fib_signal.tp_price, "Fib TP1");
               // Trade 2: No TP, managed by trailing stop
               trade.TradeOpen(0, fib_signal.order_type, volume, _Symbol, fib_signal.entry_price, fib_signal.sl_price, 0, "Fib Runner");
            }
         }
         else // Single trade with one TP
         {
            double volume = CalculateVolume(fib_signal.entry_price, fib_signal.sl_price, is_buy);
            if(volume > 0)
            {
               trade.TradeOpen(0, fib_signal.order_type, volume, _Symbol, fib_signal.entry_price, fib_signal.sl_price, fib_signal.tp_price, "Fib Full TP");
            }
         }
         return; // Stop scanning if a Fib trade was placed
      }
   }

   // --- STRATEGY 2: Original SMC (BOS) Strategy ---
   ENUM_MARKET_REGIME regime = checkMarketRegime();
   if(regime == SIDEWAYS_RANGE) return;

   BOS_Info bos = detectBOS(1, regime);
   if(!bos.detected) return;

   OB_Info ob = detectOrderBlock(bos.bar_index, regime);
   FVG_Info fvg = detectFVG(bos.bar_index, regime);
   if(!(ob.detected || fvg.detected)) return;

   double entry_price=0.0, sl=0.0, tp=0.0;
   bool is_buy = (regime == BULLISH_TREND);

   if(ob.detected)
   {
      entry_price = is_buy ? ob.top : ob.bottom;
      sl = is_buy ? ob.bottom : ob.top;
      DrawRectangle(StringFormat("SMC_EA_OB_%d", bos.bar_index), iTime(_Symbol, _Period, bos.bar_index), ob.top, iTime(_Symbol, _Period, 0), ob.bottom, is_buy ? Bullish_Zone_Color : Bearish_Zone_Color, "OB");
   }
   else
   {
      entry_price = is_buy ? fvg.top : fvg.bottom;
      sl = is_buy ? fvg.bottom : fvg.top;
      DrawRectangle(StringFormat("SMC_EA_FVG_%d", bos.bar_index), iTime(_Symbol, _Period, bos.bar_index), fvg.top, iTime(_Symbol, _Period, bos.bar_index-2), fvg.bottom, is_buy ? Bullish_Zone_Color : Bearish_Zone_Color, "FVG");
   }

   tp = is_buy ? entry_price + (entry_price - sl) * Take_Profit_RR_Ratio : entry_price - (sl - entry_price) * Take_Profit_RR_Ratio;
   double volume = CalculateVolume(entry_price, sl, is_buy);
   if(volume <= 0.0) return;

   // Place pending order
   datetime expiry_time = TimeCurrent() + (Pending_Order_Expiry_Bars * PeriodSeconds());
   if(is_buy)
      trade.BuyLimit(volume, entry_price, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry_time, "SMC EA Buy Limit");
   else
      trade.SellLimit(volume, entry_price, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry_time, "SMC EA Sell Limit");

   // Draw BOS line
   int swing_bar_idx = is_buy ? findLastSwingHigh(bos.bar_index + 1, Swing_Lookaround_Bars) : findLastSwingLow(bos.bar_index + 1, Swing_Lookaround_Bars);
   if(swing_bar_idx != -1)
   {
      double swing_price = is_buy ? iHigh(_Symbol, _Period, swing_bar_idx) : iLow(_Symbol, _Period, swing_bar_idx);
      DrawLine(StringFormat("SMC_EA_BOS_%d", bos.bar_index), iTime(_Symbol, _Period, swing_bar_idx), swing_price, iTime(_Symbol, _Period, bos.bar_index), swing_price, BOS_Line_Color);
   }
}

//+------------------------------------------------------------------+
