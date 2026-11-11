import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
    return convertToMoney(
      Provider.of<AllWallets>(context, listen: false),
      amount,
      currencyKey: widget.wallet.currency,
    );
  }

  void _showConfigureCardDialog() async {
    final allWallets = await database.getAllWallets();
    final candidateParents = allWallets
        .where((w) => w.walletPk != widget.wallet.walletPk)
        .toList();

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
    String? selectedParentPk = _config.sharedParentWalletPk;

    if (!mounted) return;

    openPopup(
      context,
      title: "Credit Card Billing Settings",
      description:
          "Configure billing cycle, grace period, interest rates, and shared credit limits:",
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
        _config.sharedParentWalletPk = selectedParentPk;

        if (selectedParentPk != null) {
          final parentCfg =
              CreditCardManager.instance.getConfig(selectedParentPk!);
          if (parentCfg.isEnabled) {
            _config.creditLimit = parentCfg.creditLimit;
          }
        }

        await CreditCardManager.instance.saveConfig(_config);
        setState(() {});
        popRoute(context);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context),
      beforeDescriptionWidget: StatefulBuilder(
        builder: (context, setDialogState) {
          final theme = Theme.of(context);
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

                // Shared Credit Limit Pool selector
                TextFont(
                  text: "Shared Credit Limit",
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          theme.colorScheme.outlineVariant.withOpacity(0.5),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: selectedParentPk,
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: TextFont(
                            text: "Independent Credit Limit (Not Linked)",
                            fontSize: 13,
                          ),
                        ),
                        ...candidateParents.map((w) {
                          return DropdownMenuItem<String?>(
                            value: w.walletPk,
                            child: Row(
                              children: [
                                const Icon(Icons.link_rounded,
                                    size: 16, color: Colors.blue),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: TextFont(
                                    text: "Share Limit with ${w.name}",
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                      onChanged: (val) {
                        setDialogState(() {
                          selectedParentPk = val;
                          if (val != null) {
                            final parentCfg = CreditCardManager.instance
                                .getConfig(val);
                            limitController.text =
                                parentCfg.creditLimit.toStringAsFixed(0);
                          }
                        });
                      },
                    ),
                  ),
                ),
                if (selectedParentPk != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 16, color: Colors.blue.shade800),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextFont(
                            text:
                                "Linked card: Total credit limit & available balance are shared with ${candidateParents.firstWhereOrNull((w) => w.walletPk == selectedParentPk)?.name ?? 'Primary Card'}. Combined utilization will be tracked together.",
                            fontSize: 11,
                            textColor: Colors.blue.shade900,
                            maxLines: 3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                TextInput(
                  labelText: selectedParentPk != null
                      ? "Shared Credit Limit (Managed by Primary Card)"
                      : "Credit Limit",
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

            // Shared Credit Limit Pool Card (if this card shares limits with other cards)
            FutureBuilder<CreditCardCombinedSummary?>(
              future: CreditCardManager.instance
                  .getCombinedSummary(widget.wallet.walletPk),
              builder: (context, poolSnapshot) {
                final pool = poolSnapshot.data;
                if (pool == null || !pool.isSharedPool) {
                  return const SizedBox.shrink();
                }

                final utilPercent = pool.combinedUtilizationPercent;
                final utilColor = utilPercent < 30.0
                    ? Colors.green.shade600
                    : (utilPercent < 70.0
                        ? Colors.amber.shade700
                        : Colors.red.shade700);

                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.blue.withOpacity(0.3),
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
                                    size: 18, color: Colors.blue.shade800),
                                const SizedBox(width: 6),
                                TextFont(
                                  text: "Shared Credit Limit Pool",
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  textColor: Colors.blue.shade900,
                                ),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: utilColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: TextFont(
                                text:
                                    "${utilPercent.toStringAsFixed(1)}% Pool Utilized",
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                textColor: utilColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Progress Bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: (utilPercent / 100.0).clamp(0.0, 1.0),
                            backgroundColor: Colors.grey.withOpacity(0.2),
                            valueColor:
                                AlwaysStoppedAnimation<Color>(utilColor),
                            minHeight: 6,
                          ),
                        ),
                        const SizedBox(height: 12),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextFont(
                                  text: "Combined Outstanding",
                                  fontSize: 11,
                                  textColor: getColor(context, "textLight"),
                                ),
                                const SizedBox(height: 2),
                                TextFont(
                                  text: getCurrencyString(
                                      pool.totalCombinedOutstanding),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                TextFont(
                                  text: "Shared Available Limit",
                                  fontSize: 11,
                                  textColor: getColor(context, "textLight"),
                                ),
                                const SizedBox(height: 2),
                                TextFont(
                                  text:
                                      "${getCurrencyString(pool.totalSharedAvailableCredit)} / ${getCurrencyString(pool.sharedCreditLimit)}",
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  textColor: Colors.blue.shade900,
                                ),
                              ],
                            ),
                          ],
                        ),
                        const Divider(height: 20),

                        TextFont(
                          text: "Cards in this Shared Pool:",
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          textColor: getColor(context, "textLight"),
                        ),
                        const SizedBox(height: 6),
                        ...pool.members.map((m) {
                          final isCurrent =
                              m.wallet.walletPk == widget.wallet.walletPk;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      m.isPrimary
                                          ? Icons.credit_card_rounded
                                          : Icons.add_card_rounded,
                                      size: 15,
                                      color: isCurrent
                                          ? theme.colorScheme.primary
                                          : Colors.grey,
                                    ),
                                    const SizedBox(width: 6),
                                    TextFont(
                                      text: m.wallet.name,
                                      fontSize: 12,
                                      fontWeight: isCurrent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    if (isCurrent) ...[
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary
                                              .withOpacity(0.12),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: TextFont(
                                          text: "This Card",
                                          fontSize: 9,
                                          textColor:
                                              theme.colorScheme.primary,
                                        ),
                                      ),
                                    ] else if (m.isPrimary) ...[
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.withOpacity(0.12),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: TextFont(
                                          text: "Primary",
                                          fontSize: 9,
                                          textColor: Colors.blue.shade800,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                TextFont(
                                  text: getCurrencyString(m.currentBalance),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  ),
                );
              },
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
