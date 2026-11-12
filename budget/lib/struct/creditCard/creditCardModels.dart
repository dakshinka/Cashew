import 'dart:convert';
import 'package:budget/database/tables.dart';

class CreditCardConfig {
  final String walletPk;
  double creditLimit;
  int billingCycleDay; // e.g. 15 (statement date is 15th of each month)
  int gracePeriodDays; // e.g. 20 (payment due 20 days after statement)
  double monthlyInterestRate; // e.g. 3.5 (3.5% per month)
  double minimumDuePercent; // e.g. 5.0 (5%)
  double taxRate; // e.g. 18.0 (18% GST on finance charges)
  bool isEnabled;
  String? sharedParentWalletPk; // If set, this card shares its limit with the primary card

  // Statement Baseline Tracking from Official Statements
  double lastStatementBalance; // e.g. 56477.0 (Total Amount Due from last statement)
  double lastStatementMinDue; // e.g. 2824.0 (Minimum Amount Due from last statement)
  DateTime? lastStatementDate; // e.g. 2026-10-20
  DateTime? lastPaymentDueDate; // e.g. 2026-11-09
  double lastStatementFinanceCharges; // Finance charges reported on statement
  double lastStatementGst; // GST / Taxes reported on statement

  CreditCardConfig({
    required this.walletPk,
    this.creditLimit = 100000.0,
    this.billingCycleDay = 15,
    this.gracePeriodDays = 20,
    this.monthlyInterestRate = 3.5,
    this.minimumDuePercent = 5.0,
    this.taxRate = 18.0,
    this.isEnabled = false,
    this.sharedParentWalletPk,
    this.lastStatementBalance = 0.0,
    this.lastStatementMinDue = 0.0,
    this.lastStatementDate,
    this.lastPaymentDueDate,
    this.lastStatementFinanceCharges = 0.0,
    this.lastStatementGst = 0.0,
  });

  bool get isSharedLimit =>
      sharedParentWalletPk != null && sharedParentWalletPk!.isNotEmpty;

  double get apr => monthlyInterestRate * 12.0;

  double get dailyPeriodicRate => (apr / 365.0) / 100.0;

  /// Determines the previous statement date, next statement date, and payment due date for a reference date
  Map<String, DateTime> getCycleDates(DateTime referenceDate) {
    final now = referenceDate;
    DateTime statementDate;
    if (now.day >= billingCycleDay) {
      statementDate = DateTime(now.year, now.month, billingCycleDay);
    } else {
      statementDate = DateTime(now.year, now.month - 1, billingCycleDay);
    }
    final previousStatementDate =
        DateTime(statementDate.year, statementDate.month - 1, billingCycleDay);
    final paymentDueDate =
        statementDate.add(Duration(days: gracePeriodDays));
    final nextStatementDate =
        DateTime(statementDate.year, statementDate.month + 1, billingCycleDay);

    return {
      'previousStatement': previousStatementDate,
      'statement': statementDate,
      'paymentDue': paymentDueDate,
      'nextStatement': nextStatementDate,
    };
  }

  Map<String, dynamic> toJson() => {
        'walletPk': walletPk,
        'creditLimit': creditLimit,
        'billingCycleDay': billingCycleDay,
        'gracePeriodDays': gracePeriodDays,
        'monthlyInterestRate': monthlyInterestRate,
        'minimumDuePercent': minimumDuePercent,
        'taxRate': taxRate,
        'isEnabled': isEnabled,
        'sharedParentWalletPk': sharedParentWalletPk,
        'lastStatementBalance': lastStatementBalance,
        'lastStatementMinDue': lastStatementMinDue,
        'lastStatementDate': lastStatementDate?.toIso8601String(),
        'lastPaymentDueDate': lastPaymentDueDate?.toIso8601String(),
        'lastStatementFinanceCharges': lastStatementFinanceCharges,
        'lastStatementGst': lastStatementGst,
      };

  factory CreditCardConfig.fromJson(Map<String, dynamic> json) =>
      CreditCardConfig(
        walletPk: json['walletPk'] as String,
        creditLimit: (json['creditLimit'] as num?)?.toDouble() ?? 100000.0,
        billingCycleDay: (json['billingCycleDay'] as int?) ?? 15,
        gracePeriodDays: (json['gracePeriodDays'] as int?) ?? 20,
        monthlyInterestRate:
            (json['monthlyInterestRate'] as num?)?.toDouble() ?? 3.5,
        minimumDuePercent:
            (json['minimumDuePercent'] as num?)?.toDouble() ?? 5.0,
        taxRate: (json['taxRate'] as num?)?.toDouble() ?? 18.0,
        isEnabled: (json['isEnabled'] as bool?) ?? false,
        sharedParentWalletPk: json['sharedParentWalletPk'] as String?,
        lastStatementBalance:
            (json['lastStatementBalance'] as num?)?.toDouble() ?? 0.0,
        lastStatementMinDue:
            (json['lastStatementMinDue'] as num?)?.toDouble() ?? 0.0,
        lastStatementDate: json['lastStatementDate'] != null
            ? DateTime.tryParse(json['lastStatementDate'] as String)
            : null,
        lastPaymentDueDate: json['lastPaymentDueDate'] != null
            ? DateTime.tryParse(json['lastPaymentDueDate'] as String)
            : null,
        lastStatementFinanceCharges:
            (json['lastStatementFinanceCharges'] as num?)?.toDouble() ?? 0.0,
        lastStatementGst:
            (json['lastStatementGst'] as num?)?.toDouble() ?? 0.0,
      );

  CreditCardConfig copyWith({
    String? walletPk,
    double? creditLimit,
    int? billingCycleDay,
    int? gracePeriodDays,
    double? monthlyInterestRate,
    double? minimumDuePercent,
    double? taxRate,
    bool? isEnabled,
    String? sharedParentWalletPk,
    double? lastStatementBalance,
    double? lastStatementMinDue,
    DateTime? lastStatementDate,
    DateTime? lastPaymentDueDate,
    double? lastStatementFinanceCharges,
    double? lastStatementGst,
  }) {
    return CreditCardConfig(
      walletPk: walletPk ?? this.walletPk,
      creditLimit: creditLimit ?? this.creditLimit,
      billingCycleDay: billingCycleDay ?? this.billingCycleDay,
      gracePeriodDays: gracePeriodDays ?? this.gracePeriodDays,
      monthlyInterestRate: monthlyInterestRate ?? this.monthlyInterestRate,
      minimumDuePercent: minimumDuePercent ?? this.minimumDuePercent,
      taxRate: taxRate ?? this.taxRate,
      isEnabled: isEnabled ?? this.isEnabled,
      sharedParentWalletPk: sharedParentWalletPk ?? this.sharedParentWalletPk,
      lastStatementBalance: lastStatementBalance ?? this.lastStatementBalance,
      lastStatementMinDue: lastStatementMinDue ?? this.lastStatementMinDue,
      lastStatementDate: lastStatementDate ?? this.lastStatementDate,
      lastPaymentDueDate: lastPaymentDueDate ?? this.lastPaymentDueDate,
      lastStatementFinanceCharges:
          lastStatementFinanceCharges ?? this.lastStatementFinanceCharges,
      lastStatementGst: lastStatementGst ?? this.lastStatementGst,
    );
  }
}

class ItemizedInterestEntry {
  final Transaction transaction;
  final int daysAccruing;
  final double interestAmount;
  final String explanation;

  ItemizedInterestEntry({
    required this.transaction,
    required this.daysAccruing,
    required this.interestAmount,
    required this.explanation,
  });
}

class CreditCardAnalysisResult {
  final double currentBalance;
  final double creditLimit;
  final double availableCredit;
  final double statementBalance;
  final double statementBalanceRemaining;
  final double amountPaidSinceStatement;
  final bool isStatementPaidInFull;
  final double newSpendsSinceStatement;
  final bool isGracePeriodActive;
  final double accruedInterest;
  final double taxOnInterest;
  final double totalFinanceCharges;
  final double dailyAccrualRate;
  final double totalDue;
  final double minimumAmountDue;
  final double minimumDueRemaining;
  final DateTime statementDate;
  final DateTime paymentDueDate;
  final List<ItemizedInterestEntry> itemizedEntries;

  CreditCardAnalysisResult({
    required this.currentBalance,
    required this.creditLimit,
    required this.availableCredit,
    required this.statementBalance,
    required this.statementBalanceRemaining,
    required this.amountPaidSinceStatement,
    required this.isStatementPaidInFull,
    required this.newSpendsSinceStatement,
    required this.isGracePeriodActive,
    required this.accruedInterest,
    required this.taxOnInterest,
    required this.totalFinanceCharges,
    required this.dailyAccrualRate,
    required this.totalDue,
    required this.minimumAmountDue,
    required this.minimumDueRemaining,
    required this.statementDate,
    required this.paymentDueDate,
    required this.itemizedEntries,
  });

  static CreditCardAnalysisResult analyze({
    required CreditCardConfig config,
    required List<Transaction> transactions,
    DateTime? asOfDate,
  }) {
    final now = asOfDate ?? DateTime.now();
    final cycle = config.getCycleDates(now);
    final cycleStatementDate = cycle['statement']!;
    final cycleDueDate = cycle['paymentDue']!;

    // Baseline statement dates & amounts (from official statement upload if present)
    final DateTime effStatementDate =
        config.lastStatementDate ?? cycleStatementDate;
    final DateTime effDueDate = config.lastPaymentDueDate ?? cycleDueDate;

    double baseStatementBalance = config.lastStatementBalance;
    double preStatementSpends = 0.0;
    double newSpends = 0.0;
    double paymentsAfterStatement = 0.0;
    final List<Transaction> postStatementSpends = [];

    for (final t in transactions) {
      if (!t.paid) continue;
      // In Cashew, for an expense account, expense has income == false
      // Repayments have income == true
      if (t.income == false) {
        if (t.dateCreated.isBefore(effStatementDate)) {
          preStatementSpends += t.amount.abs();
        } else {
          newSpends += t.amount.abs();
          postStatementSpends.add(t);
        }
      } else {
        // Payments / Repayments after statement date
        if (!t.dateCreated.isBefore(effStatementDate)) {
          paymentsAfterStatement += t.amount.abs();
        }
      }
    }

    // If no official statement balance was uploaded/set, use pre-statement spends from DB
    if (baseStatementBalance <= 0.0 && preStatementSpends > 0.0) {
      baseStatementBalance = preStatementSpends;
    }

    // Remaining statement balance after payments received
    final double statementRemaining =
        (baseStatementBalance - paymentsAfterStatement)
            .clamp(0.0, double.infinity);

    // Official Minimum Amount Due (from statement, or percentage of statement balance)
    double baseMinDue = config.lastStatementMinDue;
    if (baseMinDue <= 0.0 && baseStatementBalance > 0.0) {
      baseMinDue =
          baseStatementBalance * (config.minimumDuePercent / 100.0);
    }
    final double minDueRemaining =
        (baseMinDue - paymentsAfterStatement).clamp(0.0, baseMinDue);

    // Grace Period Logic:
    // If statement balance > 0:
    // Did user pay 100% of the statement balance before or on the due date?
    final bool isPaidInFull =
        paymentsAfterStatement >= (baseStatementBalance - 0.01);
    final bool pastDueDate = now.isAfter(effDueDate);

    bool isGracePeriodActive = true;
    if (baseStatementBalance > 0) {
      if (!isPaidInFull && pastDueDate) {
        isGracePeriodActive = false;
      }
    }

    double totalInterest = 0.0;
    final List<ItemizedInterestEntry> itemized = [];
    final dpr = config.dailyPeriodicRate;

    if (!isGracePeriodActive && config.isEnabled) {
      // Grace period revoked!
      // 1. Unpaid statement balance incurs daily interest
      if (statementRemaining > 0) {
        final daysOverdue =
            now.difference(effDueDate).inDays.clamp(1, 365);
        final stmtInterest = statementRemaining * dpr * daysOverdue;
        totalInterest += stmtInterest;

        itemized.add(ItemizedInterestEntry(
          transaction: Transaction(
            transactionPk: 'stmt_overdue',
            name: 'Unpaid Statement Balance',
            amount: -statementRemaining,
            note:
                'Carried forward from ${effStatementDate.day}/${effStatementDate.month} statement',
            categoryFk: '',
            walletFk: config.walletPk,
            dateCreated: effStatementDate,
            income: false,
            paid: true,
            skipPaid: false,
          ),
          daysAccruing: daysOverdue,
          interestAmount: stmtInterest,
          explanation:
              "${daysOverdue} days overdue @ ${(dpr * 100).toStringAsFixed(3)}%/day",
        ));
      }

      // 2. New purchases incur interest from their purchase date!
      for (final s in postStatementSpends) {
        final days = now.difference(s.dateCreated).inDays.clamp(1, 365);
        final itemInterest = s.amount.abs() * dpr * days;
        totalInterest += itemInterest;

        itemized.add(ItemizedInterestEntry(
          transaction: s,
          daysAccruing: days,
          interestAmount: itemInterest,
          explanation:
              "${days} days @ ${(dpr * 100).toStringAsFixed(3)}%/day from ${s.dateCreated.day}/${s.dateCreated.month}",
        ));
      }
    }

    // Add prior statement finance charges if carried forward
    if (statementRemaining > 0 && config.lastStatementFinanceCharges > 0) {
      totalInterest += config.lastStatementFinanceCharges;
    }

    final double tax = totalInterest * (config.taxRate / 100.0);
    final double totalCharges = totalInterest + tax;

    // Total Current Outstanding:
    // Statement Balance Remaining + New Spends + Accrued Charges
    final double currentBalance =
        statementRemaining + newSpends + totalCharges;
    final double dailyAccrual = currentBalance * dpr;

    final double availableCredit =
        (config.creditLimit - currentBalance).clamp(0.0, config.creditLimit);

    final double totalDue = currentBalance;
    final double minDue = minDueRemaining > 0
        ? minDueRemaining
        : (totalDue * (config.minimumDuePercent / 100.0)).clamp(0.0, totalDue);

    return CreditCardAnalysisResult(
      currentBalance: currentBalance,
      creditLimit: config.creditLimit,
      availableCredit: availableCredit,
      statementBalance: baseStatementBalance,
      statementBalanceRemaining: statementRemaining,
      amountPaidSinceStatement: paymentsAfterStatement,
      isStatementPaidInFull: isPaidInFull,
      newSpendsSinceStatement: newSpends,
      isGracePeriodActive: isGracePeriodActive,
      accruedInterest: totalInterest,
      taxOnInterest: tax,
      totalFinanceCharges: totalCharges,
      dailyAccrualRate: dailyAccrual,
      totalDue: totalDue,
      minimumAmountDue: minDue,
      minimumDueRemaining: minDueRemaining,
      statementDate: effStatementDate,
      paymentDueDate: effDueDate,
      itemizedEntries: itemized,
    );
  }
}

class CreditCardMemberInfo {
  final TransactionWallet wallet;
  final double currentBalance;
  final bool isPrimary;
  final CreditCardConfig config;

  CreditCardMemberInfo({
    required this.wallet,
    required this.currentBalance,
    required this.isPrimary,
    required this.config,
  });
}

class CreditCardCombinedSummary {
  final TransactionWallet primaryWallet;
  final List<CreditCardMemberInfo> members;
  final bool isSharedPool;
  final double sharedCreditLimit;
  final double totalCombinedOutstanding;
  final double totalSharedAvailableCredit;
  final double combinedUtilizationPercent;

  CreditCardCombinedSummary({
    required this.primaryWallet,
    required this.members,
    required this.isSharedPool,
    required this.sharedCreditLimit,
    required this.totalCombinedOutstanding,
    required this.totalSharedAvailableCredit,
    required this.combinedUtilizationPercent,
  });
}
