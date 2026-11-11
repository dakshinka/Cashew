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
      );
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
  final double amountPaidSinceStatement;
  final bool isGracePeriodActive;
  final double accruedInterest;
  final double taxOnInterest;
  final double totalFinanceCharges;
  final double dailyAccrualRate;
  final double totalDue;
  final double minimumAmountDue;
  final DateTime statementDate;
  final DateTime paymentDueDate;
  final List<ItemizedInterestEntry> itemizedEntries;

  CreditCardAnalysisResult({
    required this.currentBalance,
    required this.creditLimit,
    required this.availableCredit,
    required this.statementBalance,
    required this.amountPaidSinceStatement,
    required this.isGracePeriodActive,
    required this.accruedInterest,
    required this.taxOnInterest,
    required this.totalFinanceCharges,
    required this.dailyAccrualRate,
    required this.totalDue,
    required this.minimumAmountDue,
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
    final statementDate = cycle['statement']!;
    final previousStatementDate = cycle['previousStatement']!;
    final paymentDueDate = cycle['paymentDue']!;

    double totalSpends = 0.0;
    double totalRepayments = 0.0;
    double statementSpends = 0.0;
    double paymentsAfterStatement = 0.0;

    final List<Transaction> spends = [];

    for (final t in transactions) {
      if (!t.paid) continue;
      // In Cashew, for an expense account, expense has income == false
      // Repayments have income == true
      if (t.income == false) {
        totalSpends += t.amount.abs();
        spends.add(t);
        if (t.dateCreated.isBefore(statementDate)) {
          statementSpends += t.amount.abs();
        }
      } else {
        totalRepayments += t.amount.abs();
        if (t.dateCreated.isAfter(statementDate)) {
          paymentsAfterStatement += t.amount.abs();
        }
      }
    }

    final double currentBalance =
        (totalSpends - totalRepayments).clamp(0.0, double.infinity);
    final double statementBalance = statementSpends.clamp(0.0, double.infinity);

    // Grace Period Logic:
    // If statement balance > 0, and user did not pay 100% of statement balance before due date,
    // the grace period is revoked!
    final bool pastDueDate = now.isAfter(paymentDueDate);
    bool isGracePeriodActive = true;

    if (statementBalance > 0) {
      if (paymentsAfterStatement < statementBalance && pastDueDate) {
        isGracePeriodActive = false;
      }
    }

    double totalInterest = 0.0;
    final List<ItemizedInterestEntry> itemized = [];
    final dpr = config.dailyPeriodicRate;

    if (!isGracePeriodActive && config.isEnabled) {
      // Grace period revoked!
      // Interest is charged on EACH transaction from the exact purchase date!
      for (final s in spends) {
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

    final double tax = totalInterest * (config.taxRate / 100.0);
    final double totalCharges = totalInterest + tax;
    final double dailyAccrual = currentBalance * dpr;

    final double totalDue = currentBalance + totalCharges;
    final double minDue = (totalDue * (config.minimumDuePercent / 100.0))
        .clamp(0.0, totalDue);

    return CreditCardAnalysisResult(
      currentBalance: currentBalance,
      creditLimit: config.creditLimit,
      availableCredit:
          (config.creditLimit - currentBalance).clamp(0.0, config.creditLimit),
      statementBalance: statementBalance,
      amountPaidSinceStatement: paymentsAfterStatement,
      isGracePeriodActive: isGracePeriodActive,
      accruedInterest: totalInterest,
      taxOnInterest: tax,
      totalFinanceCharges: totalCharges,
      dailyAccrualRate: dailyAccrual,
      totalDue: totalDue,
      minimumAmountDue: minDue,
      statementDate: statementDate,
      paymentDueDate: paymentDueDate,
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
