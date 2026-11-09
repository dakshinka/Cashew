enum CashFlowEventType {
  currentBalance,
  salaryOrIncome,
  subscription,
  scheduledExpense,
  dailyVendorTab,
  creditCardDue,
  loanInterest,
  dailyBurnDiscretionary,
}

class CashFlowDayPoint {
  final DateTime date;
  final double startingBalance;
  final double endingBalance;
  final double netChange;
  final List<CashFlowEvent> events;

  CashFlowDayPoint({
    required this.date,
    required this.startingBalance,
    required this.endingBalance,
    required this.netChange,
    required this.events,
  });
}

class CashFlowEvent {
  final String title;
  final double amount; // Positive for inflow, negative for outflow
  final CashFlowEventType type;
  final String? walletName;

  CashFlowEvent({
    required this.title,
    required this.amount,
    required this.type,
    this.walletName,
  });
}

class CashFlowForecastSummary {
  final double startingBalance;
  final double projectedEndOfMonthBalance;
  final double lowestProjectedBalance;
  final DateTime lowestBalanceDate;
  final double totalExpectedInflow;
  final double totalCommittedOutflow;
  final double estimatedDiscretionarySpend;
  final double safeDailySpendRemaining;
  final int daysRemainingInMonth;
  final List<CashFlowDayPoint> dayPoints;
  final bool hasOverdraftRisk;

  CashFlowForecastSummary({
    required this.startingBalance,
    required this.projectedEndOfMonthBalance,
    required this.lowestProjectedBalance,
    required this.lowestBalanceDate,
    required this.totalExpectedInflow,
    required this.totalCommittedOutflow,
    required this.estimatedDiscretionarySpend,
    required this.safeDailySpendRemaining,
    required this.daysRemainingInMonth,
    required this.dayPoints,
    required this.hasOverdraftRisk,
  });
}
