//+------------------------------------------------------------------+
//|                                     Continuous_Breakout_EA.mq5   |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      ""
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "--- Order Settings ---"
input int      InpPendingDistance = 100;       // Distance from Price for Pending Orders (Points)
input int      InpStopLoss        = 100;       // Initial Stop Loss (Points)
input ulong    InpMagicNumber     = 123456;    // Magic Number

input group "--- Trailing Stop Settings ---"
input bool     InpUseTrailing     = true;      // Enable Trailing Stop
input int      InpTrailingStop    = 50;        // Trailing Distance (Points)
input int      InpTrailingStep    = 10;        // Trailing Step (Points)

//--- Strict Constants
#define STRICT_LOT_SIZE 0.01

//--- Global Variables
CTrade         g_trade;
int            g_expirationMode;
double         g_point;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_point = _Point;

   // Cache Symbol Expiration Mode once at startup to save CPU
   g_expirationMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Cleanup on removal
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   int positionCount = GetMyPositionsCount();
   int pendingCount  = GetMyPendingOrdersCount();

   // Step 1: Immediate Re-entry / Initial Setup
   // If no position exists and no pending orders exist -> Arm & Create Buy Stop + Sell Stop
   if(positionCount == 0 && pendingCount == 0)
   {
      CreateStraddlePendingOrders();
      return;
   }

   // Step 2: If position is open -> Trail Stop Loss on favorable ticks
   if(positionCount > 0 && InpUseTrailing)
   {
      ManageTrailingStop();
   }
}

//+------------------------------------------------------------------+
//| TradeTransaction function to handle immediate order cleanup      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   // Step 3: When one pending order fills and becomes a position -> Delete opposite pending order
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE || trans.type == TRADE_TRANSACTION_HISTORY_ADD)
   {
      // If a position was just opened, purge remaining pending orders for this magic number
      if(GetMyPositionsCount() > 0 && GetMyPendingOrdersCount() > 0)
      {
         DeleteAllPendingOrders();
      }
   }
}

//+------------------------------------------------------------------+
//| Create Buy Stop and Sell Stop Straddle                           |
//+------------------------------------------------------------------+
void CreateStraddlePendingOrders()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double buyStopPrice  = NormalizeDouble(ask + (InpPendingDistance * g_point), _Digits);
   double sellStopPrice = NormalizeDouble(bid - (InpPendingDistance * g_point), _Digits);

   double buySL  = (InpStopLoss > 0) ? NormalizeDouble(buyStopPrice - (InpStopLoss * g_point), _Digits) : 0;
   double sellSL = (InpStopLoss > 0) ? NormalizeDouble(sellStopPrice + (InpStopLoss * g_point), _Digits) : 0;

   // Send Buy Stop strictly locked to 0.01 lot size
   g_trade.BuyStop(STRICT_LOT_SIZE, buyStopPrice, _Symbol, buySL, 0, ORDER_TIME_GTC, 0, "Breakout BuyStop");
   
   // Send Sell Stop strictly locked to 0.01 lot size
   g_trade.SellStop(STRICT_LOT_SIZE, sellStopPrice, _Symbol, sellSL, 0, ORDER_TIME_GTC, 0, "Breakout SellStop");
}

//+------------------------------------------------------------------+
//| Trail Stop Loss on Every Favorable Tick                          |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   int total = PositionsTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double currentSL = PositionGetDouble(POSITION_SL);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

         if(type == POSITION_TYPE_BUY)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double newSL = NormalizeDouble(bid - (InpTrailingStop * g_point), _Digits);

            if(bid - openPrice > InpTrailingStop * g_point)
            {
               if(currentSL < newSL - (InpTrailingStep * g_point) || currentSL == 0)
               {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double newSL = NormalizeDouble(ask + (InpTrailingStop * g_point), _Digits);

            if(openPrice - ask > InpTrailingStop * g_point)
            {
               if(currentSL > newSL + (InpTrailingStep * g_point) || currentSL == 0)
               {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Delete All Opposite Pending Orders                       |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            g_trade.OrderDelete(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Count Active Positions for this Symbol and Magic         |
//+------------------------------------------------------------------+
int GetMyPositionsCount()
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Helper: Count Pending Orders for this Symbol and Magic           |
//+------------------------------------------------------------------+
int GetMyPendingOrdersCount()
{
   int count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(OrderGetTicket(i) > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}