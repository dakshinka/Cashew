import 'package:flutter/material.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/creditCard/creditCardManager.dart';
import 'package:budget/struct/creditCard/creditCardModels.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class CreditCardTrackerPage extends StatefulWidget {
  final TransactionWallet wallet;

  const CreditCardTrackerPage({Key? key, required this.wallet})
      : super(key: key);

  @override
  State<CreditCardTrackerPage> createState() => _CreditCardTrackerPageState();
}

class _CreditCardTrackerPageState extends State<CreditCardTrackerPage> {
  late CreditCardConfig _config;

  @override
  void initState() {
    super.initState();
    _config = CreditCardManager.instance.getConfig(widget.wallet.walletPk);
  }

  String getCurrencyString(double amount) {
    return "\$${amount.toStringAsFixed(2)}";
  }

  void _showConfigureCardDialog() {
    final limitController =
        TextEditingController(text: _config.creditLimit.toStringAsFixed(0));
    final cycleDayController =
        TextEditingController(text: _config.billingCycleDay.toString());
    final graceDaysController =
        TextEditingController(text: _config.gracePeriodDays.toString());
    final rateController =
        TextEditingController(text: _config.monthlyInterestRate.toString());
    final minDueController =
        TextEditingController(text: _config.minimumDuePercent.toString());
    final taxController =
        TextEditingController(text: _config.taxRate.toString());
    bool enabled = _config.isEnabled;

    openPopup(
      context,
      title: "Credit Card Billing Settings",
      description:
          "Configure billing cycle, grace period, and interest rates for this card:",
      onSubmitLabel: "Save Settings",
      onSubmit: () async {
        _config.creditLimit =
            double.tryParse(limitController.text.trim()) ?? 100000.0;
        _config.billingCycleDay =
            int.tryParse(cycleDayController.text.trim())?.clamp(1, 31) ?? 15;
        _config.gracePeriodDays =
            int.tryParse(graceDaysController.text.trim())?.clamp(5, 45) ?? 20;
        _config.monthlyInterestRate =
            double.tryParse(rateController.text.trim()) ?? 3.5;
        _config.minimumDuePercent =
            double.tryParse(minDueController.text.trim()) ?? 5.0;
        _config.taxRate =
            double.tryParse(taxController.text.trim()) ?? 18.0;
        _config.isEnabled = enabled;

        await CreditCardManager.instance.saveConfig(_config);
        setState(() {});
        popRoute(context);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context),
      beforeDescriptionWidget: StatefulBuilder(
        builder: (context, setDialogState) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const TextFont(
                    text: "Track Credit Card & Finance Fees",
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                  value: enabled,
                  onChanged: (val) {
                    setDialogState(() {
                      enabled = val;
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextInput(
                  labelText: "Credit Limit",
                  controller: limitController,
                  numbersOnly: true,
                  padding: const EdgeInsetsDirectional.only(bottom: 10),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextInput(
                        labelText: "Statement Day (1-31)",
                        controller: cycleDayController,
                        numbersOnly: true,
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextInput(
                        labelText: "Grace Period (Days)",
                        controller: graceDaysController,
                        numbersOnly: true,
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextInput(
                        labelText: "Monthly Rate (%)",
                        controller: rateController,
                        numbersOnly: true,
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextInput(
                        labelText: "Min Due (%)",
                        controller: minDueController,
                        numbersOnly: true,
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                      ),
                    ),
                  ],
                ),
                TextInput(
                  labelText: "Tax on Interest (% GST/VAT)",
                  controller: taxController,
                  numbersOnly: true,
                  padding: const EdgeInsetsDirectional.only(bottom: 10),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openPayCardPopup(CreditCardAnalysisResult analysis) {
    openBottomSheet(
      context,
      TransferBalancePopup(
        wallet: widget.wallet,
        allowEditWallet: true,
        initialAmount: analysis.totalDue > 0 ? analysis.totalDue : analysis.currentBalance,
        initialTitle: "Pay Credit Card (${widget.wallet.name})",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<List<Transaction>>(
      stream: database
          .getAllTransactionsFromWallet(widget.wallet.walletPk)
          .asStream(),
      builder: (context, snapshot) {
        final transactions = snapshot.data ?? [];
        final analysis = CreditCardAnalysisResult.analyze(
          config: _config,
          transactions: transactions,
        );
        final simulations = CreditCardManager.runSimulations(
          initialBalance: analysis.currentBalance > 0
              ? analysis.currentBalance
              : 50000.0,
          apr: _config.apr,
          minimumDuePercent: _config.minimumDuePercent,
        );

        return PageFramework(
          title: widget.wallet.name,
          dragDownToDismiss: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: _showConfigureCardDialog,
              tooltip: "Card Billing Settings",
            ),
          ],
          listWidgets: [
            // Grace Period Status Banner
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: analysis.isGracePeriodActive
                      ? Colors.green.withOpacity(0.12)
                      : Colors.red.withOpacity(0.12),
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
                          ? Icons.verified_user_rounded
                          : Icons.warning_amber_rounded,
                      size: 28,
                      color: analysis.isGracePeriodActive
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFont(
                            text: analysis.isGracePeriodActive
                                ? "Grace Period Active (0% Interest)"
                                : "Grace Period Revoked! Incurring Daily Interest",
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            textColor: analysis.isGracePeriodActive
                                ? Colors.green.shade800
                                : Colors.red.shade900,
                          ),
                          const SizedBox(height: 2),
                          TextFont(
                            text: analysis.isGracePeriodActive
                                ? "Full statement balance was paid. Purchases enjoy interest-free period."
                                : "Paying only minimum or partial balance revokes the grace period. Every purchase incurs interest from transaction date!",
                            fontSize: 12,
                            textColor: analysis.isGracePeriodActive
                                ? Colors.green.shade700
                                : Colors.red.shade800,
                            maxLines: 3,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Live Daily Accrual & Balance Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextFont(
                              text: "Current Outstanding",
                              fontSize: 12,
                              textColor: getColor(context, "textLight"),
                            ),
                            const SizedBox(height: 2),
                            TextFont(
                              text: getCurrencyString(analysis.currentBalance),
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            TextFont(
                              text: "Daily Interest Meter",
                              fontSize: 12,
                              textColor: getColor(context, "textLight"),
                            ),
                            const SizedBox(height: 2),
                            TextFont(
                              text:
                                  "${getCurrencyString(analysis.dailyAccrualRate)}/day",
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              textColor: Colors.red.shade700,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextFont(
                          text:
                              "Available Credit: ${getCurrencyString(analysis.availableCredit)} / ${getCurrencyString(analysis.creditLimit)}",
                          fontSize: 12,
                        ),
                        TextFont(
                          text: "APR: ${_config.apr.toStringAsFixed(1)}%",
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          textColor: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Next Statement Breakdown
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFont(
                      text: "Projected Statement & Minimum Due",
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const TextFont(text: "Total Amount Due", fontSize: 14),
                        TextFont(
                          text: getCurrencyString(analysis.totalDue),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextFont(
                          text:
                              "Accrued Finance Charges (${analysis.itemizedEntries.length} items)",
                          fontSize: 13,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextFont(
                          text:
                              "+ ${getCurrencyString(analysis.totalFinanceCharges)}",
                          fontSize: 13,
                          textColor: Colors.red.shade700,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextFont(
                          text:
                              "Minimum Amount Due (${_config.minimumDuePercent.toStringAsFixed(0)}%)",
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text: getCurrencyString(analysis.minimumAmountDue),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          textColor: Colors.amber.shade900,
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextFont(
                          text:
                              "Payment Due: ${analysis.paymentDueDate.day}/${analysis.paymentDueDate.month}/${analysis.paymentDueDate.year}",
                          fontSize: 12,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextButton(
                          onPressed: () => _openPayCardPopup(analysis),
                          child: const Text("Pay / Settle Card"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Payoff Simulator (Minimum Due Trap)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFont(
                    text: "The 'Minimum Amount Due' Trap",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  const SizedBox(height: 4),
                  TextFont(
                    text:
                        "See how much interest you pay and how long it takes to clear debt under each repayment strategy:",
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                ],
              ),
            ),

            for (final sim in simulations)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: sim.monthsToPayoff > 60
                              ? Colors.red.withOpacity(0.12)
                              : (sim.monthsToPayoff > 1
                                  ? Colors.amber.withOpacity(0.12)
                                  : Colors.green.withOpacity(0.12)),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          sim.monthsToPayoff > 60
                              ? Icons.alarm_rounded
                              : (sim.monthsToPayoff > 1
                                  ? Icons.trending_up_rounded
                                  : Icons.check_circle_rounded),
                          color: sim.monthsToPayoff > 60
                              ? Colors.red
                              : (sim.monthsToPayoff > 1
                                  ? Colors.amber.shade900
                                  : Colors.green),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextFont(
                              text: sim.label,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                            const SizedBox(height: 2),
                            TextFont(
                              text: sim.monthsToPayoff > 1
                                  ? "Takes ${sim.monthsToPayoff ~/ 12 > 0 ? '${sim.monthsToPayoff ~/ 12} yrs ' : ''}${sim.monthsToPayoff % 12} months"
                                  : "Cleared in 1 month",
                              fontSize: 12,
                              textColor: getColor(context, "textLight"),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          TextFont(
                            text: sim.totalInterestPaid > 0
                                ? "+ ${getCurrencyString(sim.totalInterestPaid)} interest"
                                : "Zero Interest",
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            textColor: sim.totalInterestPaid > 0
                                ? Colors.red.shade700
                                : Colors.green.shade700,
                          ),
                          TextFont(
                            text:
                                "Total: ${getCurrencyString(sim.totalAmountPaid)}",
                            fontSize: 11,
                            textColor: getColor(context, "textLight"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

            // Itemized Interest Breakdown
            if (analysis.itemizedEntries.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: TextFont(
                  text: "Itemized Purchase Interest",
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              for (final entry in analysis.itemizedEntries)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextFont(
                              text: entry.transaction.name,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                            TextFont(
                              text: entry.explanation,
                              fontSize: 11,
                              textColor: getColor(context, "textLight"),
                            ),
                          ],
                        ),
                        TextFont(
                          text:
                              "+ ${getCurrencyString(entry.interestAmount)}",
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          textColor: Colors.red.shade700,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 30),
          ],
        );
      },
    );
  }
}
