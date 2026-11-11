import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/creditCardTrackerPage.dart';
import 'package:budget/struct/creditCard/creditCardManager.dart';
import 'package:budget/struct/creditCard/creditCardModels.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/textWidgets.dart';

class CreditCardBannerWidget extends StatelessWidget {
  final TransactionWallet wallet;

  const CreditCardBannerWidget({Key? key, required this.wallet})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final config = CreditCardManager.instance.getConfig(wallet.walletPk);
    final isCard = config.isEnabled ||
        wallet.name.toLowerCase().contains("card") ||
        wallet.name.toLowerCase().contains("credit");
    if (!isCard) return const SizedBox.shrink();

    final allWallets = Provider.of<AllWallets>(context);

    return StreamBuilder<List<Transaction>>(
      stream: database.getAllTransactionsFromWallet(wallet.walletPk).asStream(),
      builder: (context, snapshot) {
        final transactions = snapshot.data ?? [];
        final analysis = CreditCardAnalysisResult.analyze(
          config: config,
          transactions: transactions,
        );

        final dailyAccrualStr = convertToMoney(
          allWallets,
          analysis.dailyAccrualRate,
          currencyKey: wallet.currency,
        );

        return FutureBuilder<CreditCardCombinedSummary?>(
          future: CreditCardManager.instance.getCombinedSummary(wallet.walletPk),
          builder: (context, poolSnap) {
            final pool = poolSnap.data;
            final isShared = pool != null && pool.isSharedPool;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: InkWell(
                onTap: () {
                  pushRoute(context, CreditCardTrackerPage(wallet: wallet));
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: analysis.isGracePeriodActive
                        ? Colors.green.withOpacity(0.1)
                        : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: analysis.isGracePeriodActive
                          ? Colors.green.withOpacity(0.3)
                          : Colors.red.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            analysis.isGracePeriodActive
                                ? Icons.credit_score_rounded
                                : Icons.credit_card_off_rounded,
                            color: analysis.isGracePeriodActive
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                            size: 26,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFont(
                                        text: analysis.isGracePeriodActive
                                            ? "Credit Card: Grace Period Active"
                                            : "Credit Card: Incurring Interest!",
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        textColor: analysis.isGracePeriodActive
                                            ? Colors.green.shade900
                                            : Colors.red.shade900,
                                      ),
                                    ),
                                    if (isShared)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.withOpacity(0.18),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.link_rounded,
                                                size: 11,
                                                color: Colors.blue.shade900),
                                            const SizedBox(width: 2),
                                            TextFont(
                                              text: "Shared Limit",
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                              textColor: Colors.blue.shade900,
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                                TextFont(
                                  text: analysis.isGracePeriodActive
                                      ? "0% interest • Full previous balance paid"
                                      : "Accruing $dailyAccrualStr/day • Tap for interest breakdown",
                                  fontSize: 12,
                                  textColor: analysis.isGracePeriodActive
                                      ? Colors.green.shade700
                                      : Colors.red.shade700,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                      if (isShared) ...[
                        const Divider(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextFont(
                              text:
                                  "Shared Available: ${convertToMoney(allWallets, pool.totalSharedAvailableCredit, currencyKey: wallet.currency)}",
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              textColor: Colors.blue.shade900,
                            ),
                            TextFont(
                              text:
                                  "Pool: ${pool.combinedUtilizationPercent.toStringAsFixed(1)}% Used",
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              textColor: pool.combinedUtilizationPercent > 70
                                  ? Colors.red.shade700
                                  : Colors.blue.shade900,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Home Screen Banner displaying combined credit card limit utilization and shared available credit
class HomeCreditCardSharedPoolBanner extends StatelessWidget {
  const HomeCreditCardSharedPoolBanner({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CreditCardManager.instance,
      builder: (context, _) {
        return FutureBuilder<List<CreditCardCombinedSummary>>(
          future: CreditCardManager.instance.getAllSharedPools(),
          builder: (context, snapshot) {
            final pools = snapshot.data ?? [];
            if (pools.isEmpty) return const SizedBox.shrink();

            final allWallets = Provider.of<AllWallets>(context);
            final pool = pools.first; // First active shared pool
            final util = pool.combinedUtilizationPercent;
            final utilColor = util < 30.0
                ? Colors.green.shade700
                : (util < 70.0 ? Colors.amber.shade800 : Colors.red.shade700);

            final availStr = convertToMoney(
              allWallets,
              pool.totalSharedAvailableCredit,
              currencyKey: pool.primaryWallet.currency,
            );
            final limitStr = convertToMoney(
              allWallets,
              pool.sharedCreditLimit,
              currencyKey: pool.primaryWallet.currency,
            );
            final spentStr = convertToMoney(
              allWallets,
              pool.totalCombinedOutstanding,
              currencyKey: pool.primaryWallet.currency,
            );

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: InkWell(
                onTap: () {
                  pushRoute(context,
                      CreditCardTrackerPage(wallet: pool.primaryWallet));
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withOpacity(0.18),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.25),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.link_rounded,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 6),
                              TextFont(
                                text: "Shared Credit Limit Pool",
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: utilColor.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: TextFont(
                              text: "${util.toStringAsFixed(1)}% Utilized",
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              textColor: utilColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Utilization Bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (util / 100.0).clamp(0.0, 1.0),
                          backgroundColor: Colors.grey.withOpacity(0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(utilColor),
                          minHeight: 5,
                        ),
                      ),
                      const SizedBox(height: 10),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFont(
                                text: "Shared Available Credit",
                                fontSize: 11,
                                textColor: getColor(context, "textLight"),
                              ),
                              TextFont(
                                text: "$availStr / $limitStr",
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                textColor: Theme.of(context).colorScheme.primary,
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              TextFont(
                                text: "Combined Spent",
                                fontSize: 11,
                                textColor: getColor(context, "textLight"),
                              ),
                              TextFont(
                                text: spentStr,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Cards breakdown mini-chip
                      TextFont(
                        text: pool.members
                            .map((m) =>
                                "${m.wallet.name}: ${convertToMoney(allWallets, m.currentBalance, currencyKey: m.wallet.currency)}")
                            .join("  •  "),
                        fontSize: 10.5,
                        textColor: getColor(context, "textLight"),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
