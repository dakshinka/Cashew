import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';

class SubscriptionAuditItem {
  final String subscriptionPk;
  final String name;
  final double currentAmount;
  final double? previousAmount;
  final double? priceIncreasePercent;
  final double annualizedCost;
  final DateTime nextDueDate;
  final int recurrenceDays;
  final bool isZombieCandidate;
  final String? alertReason;

  SubscriptionAuditItem({
    required this.subscriptionPk,
    required this.name,
    required this.currentAmount,
    this.previousAmount,
    this.priceIncreasePercent,
    required this.annualizedCost,
    required this.nextDueDate,
    required this.recurrenceDays,
    required this.isZombieCandidate,
    this.alertReason,
  });
}

class SubscriptionAuditor {
  /// Scans active subscriptions for price hikes and zombie recurring charges
  static Future<List<SubscriptionAuditItem>> auditSubscriptions() async {
    final List<SubscriptionAuditItem> results = [];

    List<Transaction> activeSubscriptions = [];
    try {
      activeSubscriptions = await database.getAllSubscriptions().$2;
    } catch (_) {
      return results;
    }

    final now = DateTime.now();
    final oneYearAgo = now.subtract(const Duration(days: 365));

    for (final sub in activeSubscriptions) {
      final currentAmt = sub.amount.abs();
      if (currentAmt <= 0) continue;

      // Query historical transactions with similar name
      final historical = await database.getSimilarAssociatedTitles(
        title: sub.name,
        limit: 10,
      );

      // Search all transactions in the past year matching subscription name
      final allPastTxs = await database.allTransactions;

      final matchingPastTxs = allPastTxs
          .where((t) =>
              t.dateCreated.isAfter(oneYearAgo) &&
              t.name.trim().toLowerCase() == sub.name.trim().toLowerCase() &&
              t.transactionPk != sub.transactionPk)
          .toList()
        ..sort((a, b) => b.dateCreated.compareTo(a.dateCreated));

      double? previousAmt;
      double? hikePercent;
      String? alert;
      bool isZombie = false;

      if (matchingPastTxs.isNotEmpty) {
        final lastTx = matchingPastTxs.first;
        previousAmt = lastTx.amount.abs();

        if (previousAmt > 0 && currentAmt > previousAmt + 0.5) {
          hikePercent = ((currentAmt - previousAmt) / previousAmt) * 100;
          alert =
              "Price increased by ${hikePercent.toStringAsFixed(1)}% (was ${previousAmt.toStringAsFixed(2)})";
        }
      }

      // Annualized calculation: assume 30 days if period length not set
      final periodDays = sub.periodLength ?? 30;
      final annualized = (currentAmt / periodDays) * 365.0;

      // Zombie detection: if recurrence is regular but user has 0 manual notes/edits
      if (matchingPastTxs.length >= 3 && hikePercent == null) {
        isZombie = true;
        alert = "Recurring quietly for ${matchingPastTxs.length} cycles. Review if still in use.";
      }

      results.add(
        SubscriptionAuditItem(
          subscriptionPk: sub.transactionPk,
          name: sub.name,
          currentAmount: currentAmt,
          previousAmount: previousAmt,
          priceIncreasePercent: hikePercent,
          annualizedCost: annualized,
          nextDueDate: sub.dateCreated,
          recurrenceDays: periodDays,
          isZombieCandidate: isZombie,
          alertReason: alert,
        ),
      );
    }

    return results;
  }
}
