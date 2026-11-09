import 'package:flutter/material.dart';
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
    final theme = Theme.of(context);

    return StreamBuilder<List<Transaction>>(
      stream: database.getAllTransactionsFromWallet(wallet.walletPk).asStream(),
      builder: (context, snapshot) {
        final transactions = snapshot.data ?? [];
        final analysis = CreditCardAnalysisResult.analyze(
          config: config,
          transactions: transactions,
        );

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
              child: Row(
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
                        TextFont(
                          text: analysis.isGracePeriodActive
                              ? "Credit Card: Grace Period Active"
                              : "Credit Card: Incurring Interest!",
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          textColor: analysis.isGracePeriodActive
                              ? Colors.green.shade900
                              : Colors.red.shade900,
                        ),
                        TextFont(
                          text: analysis.isGracePeriodActive
                              ? "0% interest • Full previous balance paid"
                              : "Accruing \$${analysis.dailyAccrualRate.toStringAsFixed(2)}/day • Tap for interest breakdown",
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
            ),
          ),
        );
      },
    );
  }
}
