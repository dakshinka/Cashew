import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/loans/interestLoanModels.dart';

const _uuid = Uuid();

class InterestLoanManager extends ChangeNotifier {
  static final InterestLoanManager instance = InterestLoanManager._();
  InterestLoanManager._();

  static const String _storagePrefix = "interest_loan_config_";
  final Map<String, InterestLoanConfig> _cache = {};

  void notify() {
    notifyListeners();
  }

  InterestLoanConfig getConfig(String objectivePk, {DateTime? fallbackStartDate}) {
    if (_cache.containsKey(objectivePk)) {
      return _cache[objectivePk]!;
    }

    final str = sharedPreferences.getString("$_storagePrefix$objectivePk");
    if (str != null && str.isNotEmpty) {
      try {
        final parsed = InterestLoanConfig.fromJson(jsonDecode(str));
        _cache[objectivePk] = parsed;
        return parsed;
      } catch (e) {
        debugPrint("Error parsing loan config: $e");
      }
    }

    final defaultCfg = InterestLoanConfig(
      objectivePk: objectivePk,
      startDate: fallbackStartDate ?? DateTime.now(),
      anchorDate: fallbackStartDate ?? DateTime.now(),
      isEnabled: false,
    );
    _cache[objectivePk] = defaultCfg;
    return defaultCfg;
  }

  Future<void> saveConfig(InterestLoanConfig config, {Objective? objective}) async {
    _cache[config.objectivePk] = config;
    await sharedPreferences.setString(
      "$_storagePrefix${config.objectivePk}",
      jsonEncode(config.toJson()),
    );

    if (objective != null) {
      await syncUpcomingInterestTransaction(objective: objective, config: config);
    }

    notifyListeners();
  }

  /// Synchronizes an upcoming interest transaction in the database so it appears
  /// under Upcoming Overdue Transactions and inside the Loan's detail view.
  Future<void> syncUpcomingInterestTransaction({
    required Objective objective,
    required InterestLoanConfig config,
  }) async {
    try {
      final txns = await database
          .getAllTransactionsBelongingToObjective(objective.objectivePk);

      final calc = LoanInterestCalculationResult.calculate(
        objective: objective,
        config: config,
        transactions: txns,
      );

      // Remove any previously scheduled unpaid upcoming interest transactions for this loan
      for (final t in txns) {
        if (!t.paid &&
            t.type == TransactionSpecialType.upcoming &&
            t.note.contains(INTEREST_PAYMENT_TAG)) {
          await database.deleteTransaction(t.transactionPk);
        }
      }

      // If enabled and rate > 0 and principal > 0, insert the upcoming interest transaction
      if (config.isEnabled &&
          config.interestRate > 0 &&
          calc.currentPrincipal > 0 &&
          calc.upcomingInterestAmount > 0) {
        final categories = await database.getAllCategories();
        final categoryPk =
            categories.isNotEmpty ? categories.first.categoryPk : "0";
        final wallets = await database.getAllWallets();
        final walletPk =
            wallets.isNotEmpty ? wallets.first.walletPk : "0";

        final dueFormatted =
            DateFormat('dd MMM yyyy').format(calc.nextDueDate);

        final isLent = objective.income;
        final upcomingTx = Transaction(
          transactionPk: _uuid.v4(),
          name: "${objective.name} (${config.periodLabel} Interest ${isLent ? "To Collect" : "To Pay"})",
          amount: isLent
              ? calc.upcomingInterestAmount.abs()
              : -calc.upcomingInterestAmount.abs(),
          note:
              "$INTEREST_PAYMENT_TAG Upcoming periodic interest due on $dueFormatted (${config.periodLabel})",
          categoryFk: categoryPk,
          walletFk: walletPk,
          objectiveLoanFk: objective.objectivePk,
          income: isLent,
          dateCreated: calc.nextDueDate,
          paid: false,
          skipPaid: false,
          type: TransactionSpecialType.upcoming,
          dateTimeModified: DateTime.now(),
        );

        await database.createOrUpdateTransaction(upcomingTx, insert: true);
      }
    } catch (e) {
      debugPrint("Error syncing upcoming interest transaction: $e");
    }
  }

  /// Records an Interest Payment (services the interest; principal remains unchanged)
  Future<Transaction> recordInterestPayment({
    required Objective objective,
    required double amount,
    required String walletPk,
    String? note,
  }) async {
    final categories = await database.getAllCategories();
    final String categoryPk =
        categories.isNotEmpty ? categories.first.categoryPk : "0";

    final isLent = objective.income;
    final customNote = note != null && note.isNotEmpty
        ? "$INTEREST_PAYMENT_TAG $note"
        : "$INTEREST_PAYMENT_TAG Periodic interest payment";

    final transaction = Transaction(
      transactionPk: _uuid.v4(),
      name: "${objective.name} (${isLent ? "Interest Received" : "Interest Paid"})",
      amount: isLent ? amount.abs() : -amount.abs(),
      note: customNote,
      categoryFk: categoryPk,
      walletFk: walletPk,
      objectiveLoanFk: objective.objectivePk,
      income: isLent,
      dateCreated: DateTime.now(),
      paid: true,
      skipPaid: false,
      dateTimeModified: DateTime.now(),
    );

    await database.createOrUpdateTransaction(transaction, insert: true);

    // Reschedule the next upcoming cycle
    final config = getConfig(objective.objectivePk);
    if (config.isEnabled) {
      await syncUpcomingInterestTransaction(
        objective: objective,
        config: config,
      );
    }

    notifyListeners();
    return transaction;
  }

  /// Records a Part-payment / Principal Repayment (directly reduces remaining principal balance)
  Future<Transaction> recordPrincipalRepayment({
    required Objective objective,
    required double amount,
    required String walletPk,
    String? note,
  }) async {
    final categories = await database.getAllCategories();
    final String categoryPk =
        categories.isNotEmpty ? categories.first.categoryPk : "0";

    final isLent = objective.income;
    final customNote = note != null && note.isNotEmpty
        ? "$PRINCIPAL_PAYMENT_TAG $note"
        : "$PRINCIPAL_PAYMENT_TAG Part-payment towards principal";

    final transaction = Transaction(
      transactionPk: _uuid.v4(),
      name: "${objective.name} (${isLent ? "Principal Received" : "Principal Repayment"})",
      amount: isLent ? amount.abs() : -amount.abs(),
      note: customNote,
      categoryFk: categoryPk,
      walletFk: walletPk,
      objectiveLoanFk: objective.objectivePk,
      income: isLent,
      dateCreated: DateTime.now(),
      paid: true,
      skipPaid: false,
      dateTimeModified: DateTime.now(),
    );

    await database.createOrUpdateTransaction(transaction, insert: true);

    // Update upcoming interest calculation with reduced principal
    final config = getConfig(objective.objectivePk);
    if (config.isEnabled) {
      await syncUpcomingInterestTransaction(
        objective: objective,
        config: config,
      );
    }

    notifyListeners();
    return transaction;
  }
}
