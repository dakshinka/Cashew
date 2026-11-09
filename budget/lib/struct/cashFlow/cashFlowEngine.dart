import 'package:budget/database/tables.dart';
import 'package:budget/struct/creditCard/creditCardManager.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/loans/interestLoanManager.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/vendorTabs/vendorTabManager.dart';
import 'package:budget/struct/cashFlow/cashFlowModels.dart';

class CashFlowEngine {
  /// Generate a comprehensive cash flow forecast for the specified horizon (default 30 days)
  static Future<CashFlowForecastSummary> generateForecast({
    int daysAhead = 30,
    bool includeDiscretionaryBurn = true,
    String? specificWalletPk,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOfMonth = DateTime(now.year, now.month + 1, 0);
    final daysRemainingInMonth = endOfMonth.difference(today).inDays;

    // 1. Calculate Starting Liquid Balance
    double startingBalance = 0.0;
    final wallets = await database.getAllWallets();
    for (final w in wallets) {
      if (specificWalletPk != null && w.walletPk != specificWalletPk) continue;
      // Skip credit cards or special debt wallets in liquid cash tally
      if (CreditCardManager.instance.getConfig(w.walletPk) != null) continue;
      final txs = await database.getAllTransactionsFromWallet(w.walletPk);
      double bal = 0.0;
      for (final tx in txs) {
        bal += tx.amount;
      }
      startingBalance += bal;
    }

    // 2. Compute Historical Discretionary Daily Burn Rate (Past 30 days)
    double dailyBurnRate = 0.0;
    try {
      final past30DaysStart = today.subtract(const Duration(days: 30));
      final allTxs = await database.allTransactions;
      final pastTxs = allTxs.where((t) =>
          t.dateCreated.isAfter(past30DaysStart) &&
          (specificWalletPk == null || t.walletFk == specificWalletPk)).toList();

      double nonRecurringExpenseTotal = 0.0;
      for (final tx in pastTxs) {
        if (!tx.income &&
            tx.type != TransactionSpecialType.subscription &&
            tx.type != TransactionSpecialType.upcoming) {
          nonRecurringExpenseTotal += tx.amount.abs();
        }
      }
      dailyBurnRate = nonRecurringExpenseTotal / 30.0;
    } catch (_) {}

    // 3. Fetch Subscriptions & Upcoming Scheduled Transactions
    List<Transaction> subscriptions = [];
    try {
      subscriptions = await database.getAllSubscriptions().$2;
    } catch (_) {}

    List<Transaction> upcomingScheduled = [];
    try {
      upcomingScheduled =
          await database.getAllOverdueUpcomingTransactions().$2;
    } catch (_) {}

    // 4. Calculate Daily Services (Vendor Tabs like Milk / Water)
    final dailyServices = VendorTabManager.instance.dailyServices;
    double dailyVendorTabCost = 0.0;
    for (final s in dailyServices) {
      dailyVendorTabCost +=
          s.defaultDailyQuantity * s.getPriceForDate(DateTime.now());
    }

    // 5. Build Day-by-Day Forecast
    List<CashFlowDayPoint> dayPoints = [];
    double runningBalance = startingBalance;
    double lowestBalance = startingBalance;
    DateTime lowestBalanceDate = today;
    double totalInflow = 0.0;
    double totalCommittedOutflow = 0.0;
    double totalEstimatedBurn = 0.0;

    for (int i = 0; i < daysAhead; i++) {
      final day = today.add(Duration(days: i));
      final dayStartBal = runningBalance;
      final List<CashFlowEvent> dayEvents = [];
      double dayInflow = 0.0;
      double dayOutflow = 0.0;

      // Check upcoming scheduled transactions on this day
      for (final tx in upcomingScheduled) {
        if (tx.dateCreated.year == day.year &&
            tx.dateCreated.month == day.month &&
            tx.dateCreated.day == day.day) {
          final amt = tx.amount.abs();
          if (tx.income) {
            dayInflow += amt;
            dayEvents.add(CashFlowEvent(
              title: tx.name,
              amount: amt,
              type: CashFlowEventType.salaryOrIncome,
            ));
          } else {
            dayOutflow += amt;
            dayEvents.add(CashFlowEvent(
              title: tx.name,
              amount: -amt,
              type: CashFlowEventType.scheduledExpense,
            ));
          }
        }
      }

      // Check recurring subscriptions matching day of month
      for (final sub in subscriptions) {
        if (sub.dateCreated.day == day.day) {
          final amt = sub.amount.abs();
          dayOutflow += amt;
          dayEvents.add(CashFlowEvent(
            title: "Sub: ${sub.name}",
            amount: -amt,
            type: CashFlowEventType.subscription,
          ));
        }
      }

      // Add daily vendor tab deliverable cost
      if (dailyVendorTabCost > 0) {
        dayOutflow += dailyVendorTabCost;
        dayEvents.add(CashFlowEvent(
          title: "Daily Tabs (Milk/Services)",
          amount: -dailyVendorTabCost,
          type: CashFlowEventType.dailyVendorTab,
        ));
      }

      // Add estimated discretionary burn
      if (includeDiscretionaryBurn && dailyBurnRate > 0) {
        dayOutflow += dailyBurnRate;
        totalEstimatedBurn += dailyBurnRate;
      }

      totalInflow += dayInflow;
      totalCommittedOutflow += dayOutflow;

      final netChange = dayInflow - dayOutflow;
      runningBalance += netChange;

      if (runningBalance < lowestBalance) {
        lowestBalance = runningBalance;
        lowestBalanceDate = day;
      }

      dayPoints.add(CashFlowDayPoint(
        date: day,
        startingBalance: dayStartBal,
        endingBalance: runningBalance,
        netChange: netChange,
        events: dayEvents,
      ));
    }

    // Determine projected end of current month
    double endOfMonthBal = startingBalance;
    if (daysRemainingInMonth > 0 && daysRemainingInMonth < dayPoints.length) {
      endOfMonthBal = dayPoints[daysRemainingInMonth].endingBalance;
    } else if (dayPoints.isNotEmpty) {
      endOfMonthBal = dayPoints.last.endingBalance;
    }

    // Calculate safe daily discretionary spend
    final safeDailySpend = (daysRemainingInMonth > 0 && endOfMonthBal > 0)
        ? (endOfMonthBal / daysRemainingInMonth)
        : 0.0;

    return CashFlowForecastSummary(
      startingBalance: startingBalance,
      projectedEndOfMonthBalance: endOfMonthBal,
      lowestProjectedBalance: lowestBalance,
      lowestBalanceDate: lowestBalanceDate,
      totalExpectedInflow: totalInflow,
      totalCommittedOutflow: totalCommittedOutflow,
      estimatedDiscretionarySpend: totalEstimatedBurn,
      safeDailySpendRemaining: safeDailySpend,
      daysRemainingInMonth: daysRemainingInMonth,
      dayPoints: dayPoints,
      hasOverdraftRisk: lowestBalance < 0,
    );
  }
}
