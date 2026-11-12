import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/creditCard/creditCardModels.dart';

class PayoffSimulationScenario {
  final String label;
  final int monthsToPayoff;
  final double monthlyPayment;
  final double totalInterestPaid;
  final double totalAmountPaid;

  PayoffSimulationScenario({
    required this.label,
    required this.monthsToPayoff,
    required this.monthlyPayment,
    required this.totalInterestPaid,
    required this.totalAmountPaid,
  });
}

class CreditCardManager extends ChangeNotifier {
  static final CreditCardManager instance = CreditCardManager._();
  CreditCardManager._();

  static const String _storagePrefix = "credit_card_config_";

  CreditCardConfig getConfig(String walletPk) {
    final str = sharedPreferences.getString("$_storagePrefix$walletPk");
    if (str != null && str.isNotEmpty) {
      try {
        return CreditCardConfig.fromJson(jsonDecode(str));
      } catch (e) {
        debugPrint("Error parsing credit card config: $e");
      }
    }
    return CreditCardConfig(walletPk: walletPk, isEnabled: false);
  }

  Future<void> saveConfig(CreditCardConfig config) async {
    await sharedPreferences.setString(
      "$_storagePrefix${config.walletPk}",
      jsonEncode(config.toJson()),
    );
    notifyListeners();
  }

  /// Returns the effective primary card walletPk.
  /// If the card is linked to a parent card, returns that parent's walletPk.
  String getEffectivePrimaryWalletPk(String walletPk) {
    final cfg = getConfig(walletPk);
    if (cfg.isSharedLimit && cfg.sharedParentWalletPk != walletPk) {
      return cfg.sharedParentWalletPk!;
    }
    return walletPk;
  }

  /// Checks if a wallet is part of a shared credit limit pool (either primary or linked child)
  bool isWalletInSharedPool(String walletPk) {
    final cfg = getConfig(walletPk);
    if (cfg.isSharedLimit) return true;
    for (final k in sharedPreferences.getKeys()) {
      if (k.startsWith(_storagePrefix)) {
        final val = sharedPreferences.getString(k);
        if (val != null && val.contains('"sharedParentWalletPk":"$walletPk"')) {
          return true;
        }
      }
    }
    return false;
  }

  /// Calculates outstanding card balance (statement baseline + new spends minus payments)
  static double calculateWalletBalance(
    List<Transaction> transactions, {
    CreditCardConfig? config,
  }) {
    if (config != null && config.lastStatementBalance > 0) {
      final stmtDate =
          config.lastStatementDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      final stmtDateOnly =
          DateTime(stmtDate.year, stmtDate.month, stmtDate.day);
      double paymentsAfterStmt = 0.0;
      double spendsAfterStmt = 0.0;

      for (final t in transactions) {
        if (!t.paid) continue;
        final tDateOnly =
            DateTime(t.dateCreated.year, t.dateCreated.month, t.dateCreated.day);
        final isPostStatement = tDateOnly.isAfter(stmtDateOnly);

        if (isPostStatement) {
          if (t.income == true) {
            paymentsAfterStmt += t.amount.abs();
          } else {
            spendsAfterStmt += t.amount.abs();
          }
        }
      }

      final remainingStmt =
          (config.lastStatementBalance - paymentsAfterStmt).clamp(0.0, double.infinity);
      return remainingStmt + spendsAfterStmt;
    }

    double totalSpends = 0.0;
    double totalRepayments = 0.0;
    for (final t in transactions) {
      if (!t.paid) continue;
      if (t.income == false) {
        totalSpends += t.amount.abs();
      } else {
        totalRepayments += t.amount.abs();
      }
    }
    return (totalSpends - totalRepayments).clamp(0.0, double.infinity);
  }

  /// Computes the combined multi-card summary across a shared pool (Primary + Linked Cards)
  Future<CreditCardCombinedSummary?> getCombinedSummary(
    String walletPk, {
    List<TransactionWallet>? allWallets,
  }) async {
    final wallets = allWallets ?? await database.getAllWallets();
    final primaryPk = getEffectivePrimaryWalletPk(walletPk);
    final primaryWallet =
        wallets.firstWhereOrNull((w) => w.walletPk == primaryPk);
    if (primaryWallet == null) return null;

    final primaryConfig = getConfig(primaryPk);

    // Find all child cards linked to this primary card
    final List<TransactionWallet> linkedWallets = [];
    for (final w in wallets) {
      if (w.walletPk == primaryPk) continue;
      final cfg = getConfig(w.walletPk);
      if (cfg.sharedParentWalletPk == primaryPk && cfg.isEnabled) {
        linkedWallets.add(w);
      }
    }

    final bool isShared =
        linkedWallets.isNotEmpty || (getConfig(walletPk).isSharedLimit);
    final double sharedLimit = primaryConfig.creditLimit;

    // Fetch transactions and calculate balances
    final List<CreditCardMemberInfo> members = [];
    double totalCombinedSpent = 0.0;

    // 1. Primary Card
    final primaryTxns =
        await database.getAllTransactionsFromWallet(primaryPk);
    final primaryBal =
        calculateWalletBalance(primaryTxns, config: primaryConfig);
    totalCombinedSpent += primaryBal;
    members.add(CreditCardMemberInfo(
      wallet: primaryWallet,
      currentBalance: primaryBal,
      isPrimary: true,
      config: primaryConfig,
    ));

    // 2. Linked Cards
    for (final lw in linkedWallets) {
      final txns = await database.getAllTransactionsFromWallet(lw.walletPk);
      final lConfig = getConfig(lw.walletPk);
      final bal = calculateWalletBalance(txns, config: lConfig);
      totalCombinedSpent += bal;
      members.add(CreditCardMemberInfo(
        wallet: lw,
        currentBalance: bal,
        isPrimary: false,
        config: lConfig,
      ));
    }

    final avail = (sharedLimit - totalCombinedSpent).clamp(0.0, sharedLimit);
    final util =
        sharedLimit > 0 ? (totalCombinedSpent / sharedLimit) * 100.0 : 0.0;

    return CreditCardCombinedSummary(
      primaryWallet: primaryWallet,
      members: members,
      isSharedPool: isShared,
      sharedCreditLimit: sharedLimit,
      totalCombinedOutstanding: totalCombinedSpent,
      totalSharedAvailableCredit: avail,
      combinedUtilizationPercent: util,
    );
  }

  /// Returns all active shared pools across all configured credit cards
  Future<List<CreditCardCombinedSummary>> getAllSharedPools({
    List<TransactionWallet>? allWallets,
  }) async {
    final wallets = allWallets ?? await database.getAllWallets();
    final List<CreditCardCombinedSummary> pools = [];
    final Set<String> processedPrimaryPks = {};

    for (final w in wallets) {
      final cfg = getConfig(w.walletPk);
      if (!cfg.isEnabled) continue;

      final primaryPk = getEffectivePrimaryWalletPk(w.walletPk);
      if (processedPrimaryPks.contains(primaryPk)) continue;
      processedPrimaryPks.add(primaryPk);

      final summary =
          await getCombinedSummary(primaryPk, allWallets: wallets);
      if (summary != null && summary.isSharedPool) {
        pools.add(summary);
      }
    }

    return pools;
  }

  /// Simulates payoff timeline and interest cost under different payment scenarios
  static List<PayoffSimulationScenario> runSimulations({
    required double initialBalance,
    required double apr,
    required double minimumDuePercent,
  }) {
    if (initialBalance <= 0) return [];

    final monthlyRate = (apr / 100.0) / 12.0;

    // Scenario 1: Minimum Due Only (e.g. 5% of balance, min $25)
    double balMin = initialBalance;
    double interestMin = 0.0;
    int monthsMin = 0;
    const maxMonths = 360; // 30 year cap
    while (balMin > 1.0 && monthsMin < maxMonths) {
      monthsMin++;
      final interest = balMin * monthlyRate;
      interestMin += interest;
      double payment = (balMin + interest) * (minimumDuePercent / 100.0);
      if (payment < 25.0) payment = 25.0;
      if (payment > balMin + interest) payment = balMin + interest;
      balMin = balMin + interest - payment;
    }

    // Scenario 2: Double Minimum or Fixed Payment
    final double fixedPayment = (initialBalance * 0.10).clamp(50.0, initialBalance);
    double balFixed = initialBalance;
    double interestFixed = 0.0;
    int monthsFixed = 0;
    while (balFixed > 1.0 && monthsFixed < maxMonths) {
      monthsFixed++;
      final interest = balFixed * monthlyRate;
      interestFixed += interest;
      double payment = fixedPayment;
      if (payment > balFixed + interest) payment = balFixed + interest;
      balFixed = balFixed + interest - payment;
    }

    // Scenario 3: Pay in Full (1 Month)
    final double interestFull = 0.0; // Grace period intact

    return [
      PayoffSimulationScenario(
        label: "Pay Minimum Due (${minimumDuePercent.toStringAsFixed(0)}%)",
        monthsToPayoff: monthsMin,
        monthlyPayment: (initialBalance * (minimumDuePercent / 100.0)).clamp(25.0, initialBalance),
        totalInterestPaid: interestMin,
        totalAmountPaid: initialBalance + interestMin,
      ),
      PayoffSimulationScenario(
        label: "Pay Accelerated (10% / Fixed)",
        monthsToPayoff: monthsFixed,
        monthlyPayment: fixedPayment,
        totalInterestPaid: interestFixed,
        totalAmountPaid: initialBalance + interestFixed,
      ),
      PayoffSimulationScenario(
        label: "Pay Full Statement (100%)",
        monthsToPayoff: 1,
        monthlyPayment: initialBalance,
        totalInterestPaid: interestFull,
        totalAmountPaid: initialBalance,
      ),
    ];
  }
}
