import 'package:budget/database/tables.dart';

enum LoanInterestPeriod {
  daily,
  weekly,
  monthly,
  yearly,
}

enum LoanPaymentType {
  interestPayment,
  principalRepayment,
  principalTopUp,
}

const String INTEREST_PAYMENT_TAG = "[Interest Payment]";
const String PRINCIPAL_PAYMENT_TAG = "[Principal Repayment]";
const String PRINCIPAL_TOPUP_TAG = "[Principal Disbursal]";

class InterestLoanConfig {
  final String objectivePk;
  double interestRate; // e.g. 2.0 for 2%
  LoanInterestPeriod period; // daily, weekly, monthly, yearly
  DateTime startDate;
  DateTime anchorDate; // Reference cycle date (e.g. 15th of the month, or specific day)
  bool isEnabled;

  InterestLoanConfig({
    required this.objectivePk,
    this.interestRate = 0.0,
    this.period = LoanInterestPeriod.monthly,
    required this.startDate,
    DateTime? anchorDate,
    this.isEnabled = false,
  }) : anchorDate = anchorDate ?? startDate;

  String get periodLabel {
    switch (period) {
      case LoanInterestPeriod.daily:
        return "Daily";
      case LoanInterestPeriod.weekly:
        return "Weekly";
      case LoanInterestPeriod.monthly:
        return "Monthly";
      case LoanInterestPeriod.yearly:
        return "Annual";
    }
  }

  String get perPeriodText {
    switch (period) {
      case LoanInterestPeriod.daily:
        return "per day";
      case LoanInterestPeriod.weekly:
        return "per week";
      case LoanInterestPeriod.monthly:
        return "per month";
      case LoanInterestPeriod.yearly:
        return "per year (APR)";
    }
  }

  Map<String, dynamic> toJson() => {
        'objectivePk': objectivePk,
        'interestRate': interestRate,
        'period': period.index,
        'startDate': startDate.toIso8601String(),
        'anchorDate': anchorDate.toIso8601String(),
        'isEnabled': isEnabled,
      };

  factory InterestLoanConfig.fromJson(Map<String, dynamic> json) {
    final start = json['startDate'] != null
        ? DateTime.parse(json['startDate'] as String)
        : DateTime.now();
    final anchor = json['anchorDate'] != null
        ? DateTime.parse(json['anchorDate'] as String)
        : start;

    return InterestLoanConfig(
      objectivePk: json['objectivePk'] as String,
      interestRate: (json['interestRate'] as num?)?.toDouble() ?? 0.0,
      period: LoanInterestPeriod.values[(json['period'] as int?) ?? 2],
      startDate: start,
      anchorDate: anchor,
      isEnabled: json['isEnabled'] as bool? ?? false,
    );
  }
}

class LoanInterestCalculationResult {
  final double originalPrincipal;
  final double currentPrincipal;
  final double totalPrincipalPaid;
  final double totalInterestPaid;
  final double accruedInterestDue;
  final double upcomingInterestAmount;
  final double dailyInterestAmount;
  final double weeklyInterestAmount;
  final double monthlyInterestAmount;
  final double annualInterestAmount;
  final DateTime nextDueDate;
  final DateTime anchorDate;

  LoanInterestCalculationResult({
    required this.originalPrincipal,
    required this.currentPrincipal,
    required this.totalPrincipalPaid,
    required this.totalInterestPaid,
    required this.accruedInterestDue,
    required this.upcomingInterestAmount,
    required this.dailyInterestAmount,
    required this.weeklyInterestAmount,
    required this.monthlyInterestAmount,
    required this.annualInterestAmount,
    required this.nextDueDate,
    required this.anchorDate,
  });

  static LoanInterestCalculationResult calculate({
    required Objective objective,
    required InterestLoanConfig config,
    required List<Transaction> transactions,
    double fallbackPrincipal = 0.0,
  }) {
    double initialDisbursements = 0.0;
    double principalRepayments = 0.0;
    double principalTopUps = 0.0;
    double interestPaid = 0.0;
    DateTime lastInterestPaymentDate = config.startDate;

    for (final t in transactions) {
      final note = t.note ?? "";
      final name = t.name.toLowerCase();
      final isInitial = name.contains("initial") ||
          note.toLowerCase().contains("initial") ||
          name.contains("disbursement") ||
          (transactions.length == 1 && t.income == !objective.income);

      // Do not skip initial record even if unpaid
      if (!t.paid && !isInitial) continue;

      if (note.contains(INTEREST_PAYMENT_TAG) || name.contains("(interest")) {
        interestPaid += t.amount.abs();
        if (t.dateCreated.isAfter(lastInterestPaymentDate)) {
          lastInterestPaymentDate = t.dateCreated;
        }
      } else if (note.contains(PRINCIPAL_TOPUP_TAG) || name.contains("topup")) {
        principalTopUps += t.amount.abs();
      } else if (note.contains(PRINCIPAL_PAYMENT_TAG) ||
          name.contains("part principal") ||
          name.contains("principal repayment") ||
          name.contains("principal received")) {
        principalRepayments += t.amount.abs();
      } else if (isInitial) {
        // Explicitly recognise initial disbursement record regardless of past polarity glitches
        initialDisbursements += t.amount.abs();
      } else if (t.income == !objective.income) {
        // In Cashew, initial loan disbursements and top-ups have income == !objective.income
        initialDisbursements += t.amount.abs();
      } else if (t.income == objective.income) {
        // Payments/repayments towards the loan have income == objective.income
        principalRepayments += t.amount.abs();
      }
    }

    final double effectiveInitial = initialDisbursements > 0
        ? initialDisbursements
        : (fallbackPrincipal > 0
            ? fallbackPrincipal
            : objective.amount.abs());

    final double originalPrincipal =
        effectiveInitial.clamp(0.0, double.infinity);
    final double currentPrincipal =
        (originalPrincipal + principalTopUps - principalRepayments)
            .clamp(0.0, double.infinity);

    // Calculate rates for all cycles
    final rawRate = (config.interestRate / 100.0);
    double dailyAmount = 0.0;
    double weeklyAmount = 0.0;
    double monthlyAmount = 0.0;
    double annualAmount = 0.0;

    if (currentPrincipal > 0 && config.interestRate > 0) {
      switch (config.period) {
        case LoanInterestPeriod.daily:
          dailyAmount = currentPrincipal * rawRate;
          weeklyAmount = dailyAmount * 7;
          monthlyAmount = dailyAmount * 30;
          annualAmount = dailyAmount * 365;
          break;
        case LoanInterestPeriod.weekly:
          weeklyAmount = currentPrincipal * rawRate;
          dailyAmount = weeklyAmount / 7;
          monthlyAmount = weeklyAmount * (30 / 7);
          annualAmount = weeklyAmount * 52;
          break;
        case LoanInterestPeriod.monthly:
          monthlyAmount = currentPrincipal * rawRate;
          dailyAmount = monthlyAmount / 30;
          weeklyAmount = monthlyAmount / 4.333;
          annualAmount = monthlyAmount * 12;
          break;
        case LoanInterestPeriod.yearly:
          annualAmount = currentPrincipal * rawRate;
          dailyAmount = annualAmount / 365;
          weeklyAmount = annualAmount / 52;
          monthlyAmount = annualAmount / 12;
          break;
      }
    }

    double upcomingAmount = 0.0;
    switch (config.period) {
      case LoanInterestPeriod.daily:
        upcomingAmount = dailyAmount;
        break;
      case LoanInterestPeriod.weekly:
        upcomingAmount = weeklyAmount;
        break;
      case LoanInterestPeriod.monthly:
        upcomingAmount = monthlyAmount;
        break;
      case LoanInterestPeriod.yearly:
        upcomingAmount = annualAmount;
        break;
    }

    // Determine upcoming next due date based on anchorDate
    final anchor = config.anchorDate;
    final now = DateTime.now();
    DateTime nextDue = anchor;

    if (config.isEnabled) {
      switch (config.period) {
        case LoanInterestPeriod.daily:
          if (lastInterestPaymentDate.year == now.year &&
              lastInterestPaymentDate.month == now.month &&
              lastInterestPaymentDate.day == now.day) {
            nextDue = DateTime(now.year, now.month, now.day + 1);
          } else {
            nextDue = DateTime(now.year, now.month, now.day);
          }
          break;

        case LoanInterestPeriod.weekly:
          final targetWeekday = anchor.weekday;
          int daysUntil = (targetWeekday - now.weekday) % 7;
          if (daysUntil < 0) daysUntil += 7;
          if (daysUntil == 0 &&
              lastInterestPaymentDate.isAfter(now.subtract(const Duration(days: 6)))) {
            daysUntil = 7;
          }
          nextDue = DateTime(now.year, now.month, now.day + daysUntil);
          break;

        case LoanInterestPeriod.monthly:
          final targetDay = anchor.day;
          final daysInCurrentMonth = DateTime(now.year, now.month + 1, 0).day;
          final dayThisMonth = targetDay.clamp(1, daysInCurrentMonth);
          final candidateThisMonth = DateTime(now.year, now.month, dayThisMonth);

          if (candidateThisMonth.isAfter(lastInterestPaymentDate) &&
              (candidateThisMonth.isAfter(now) ||
                  (candidateThisMonth.day == now.day &&
                      !lastInterestPaymentDate.isAfter(DateTime(now.year, now.month, 1))))) {
            nextDue = candidateThisMonth;
          } else {
            final nextMonth = now.month == 12 ? 1 : now.month + 1;
            final nextYear = now.month == 12 ? now.year + 1 : now.year;
            final daysInNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
            nextDue = DateTime(nextYear, nextMonth, targetDay.clamp(1, daysInNextMonth));
          }
          break;

        case LoanInterestPeriod.yearly:
          final candidateThisYear = DateTime(now.year, anchor.month, anchor.day.clamp(1, 28));
          if (candidateThisYear.isAfter(now) && candidateThisYear.isAfter(lastInterestPaymentDate)) {
            nextDue = candidateThisYear;
          } else {
            nextDue = DateTime(now.year + 1, anchor.month, anchor.day.clamp(1, 28));
          }
          break;
      }
    }

    // Accrued interest
    double accruedPeriods = 0.0;
    if (config.isEnabled && config.interestRate > 0 && currentPrincipal > 0) {
      final diff = now.difference(lastInterestPaymentDate);
      switch (config.period) {
        case LoanInterestPeriod.daily:
          accruedPeriods = (diff.inHours / 24.0).clamp(0.0, double.infinity);
          break;
        case LoanInterestPeriod.weekly:
          accruedPeriods = (diff.inDays / 7.0).clamp(0.0, double.infinity);
          break;
        case LoanInterestPeriod.monthly:
          final months = (now.year - lastInterestPaymentDate.year) * 12 +
              (now.month - lastInterestPaymentDate.month) +
              (now.day - lastInterestPaymentDate.day) / 30.0;
          accruedPeriods = months.clamp(0.0, double.infinity);
          break;
        case LoanInterestPeriod.yearly:
          accruedPeriods = (diff.inDays / 365.0).clamp(0.0, double.infinity);
          break;
      }
    }

    final double accruedInterestDue =
        (upcomingAmount * accruedPeriods).clamp(0.0, double.infinity);

    return LoanInterestCalculationResult(
      originalPrincipal: originalPrincipal,
      currentPrincipal: currentPrincipal,
      totalPrincipalPaid: principalRepayments,
      totalInterestPaid: interestPaid,
      accruedInterestDue: accruedInterestDue,
      upcomingInterestAmount: upcomingAmount,
      dailyInterestAmount: dailyAmount,
      weeklyInterestAmount: weeklyAmount,
      monthlyInterestAmount: monthlyAmount,
      annualInterestAmount: annualAmount,
      nextDueDate: nextDue,
      anchorDate: anchor,
    );
  }
}
