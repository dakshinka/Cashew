import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/loans/interestLoanManager.dart';
import 'package:budget/struct/loans/interestLoanModels.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class InterestLoanWidget extends StatefulWidget {
  final Objective objective;

  const InterestLoanWidget({Key? key, required this.objective})
      : super(key: key);

  @override
  State<InterestLoanWidget> createState() => _InterestLoanWidgetState();
}

class _InterestLoanWidgetState extends State<InterestLoanWidget> {
  String _formatMoney(BuildContext context, double amount) {
    return convertToMoney(Provider.of<AllWallets>(context), amount);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selfHealInitialRecord();
    });
  }

  Future<void> _selfHealInitialRecord() async {
    try {
      final txs = await database.getAllTransactionsBelongingToObjective(
        widget.objective.objectivePk,
      );
      for (final t in txs) {
        final isInitial = t.name.toLowerCase().contains("initial") ||
            (t.note != null && t.note!.toLowerCase().contains("initial"));
        if (isInitial) {
          // Borrowed (objective.income == false): Initial Record is Income (income: true, positive amount)
          // Lent (objective.income == true): Initial Record is Expense (income: false, negative amount)
          final expectedIncome = !widget.objective.income;
          final expectedAmount = t.amount.abs() * (expectedIncome ? 1 : -1);
          if (t.income != expectedIncome || t.amount != expectedAmount) {
            await database.createOrUpdateTransaction(
              t.copyWith(
                income: expectedIncome,
                amount: expectedAmount,
              ),
              insert: false,
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Error self-healing initial record: $e");
    }
  }

  Future<void> _toggleLoanType() async {
    final newIncome = !widget.objective.income;
    final newLabel = newIncome ? "Lent (Credit)" : "Borrowed (Debt)";

    openPopup(
      context,
      title: "Switch Loan to $newLabel?",
      description: newIncome
          ? "Switching to Lent means you gave money to someone.\n\n• Initial loan disbursement will be recorded as Expense (Red).\n• Periodic interest and principal return you collect will be Income (Green)."
          : "Switching to Borrowed means you received money from someone.\n\n• Initial loan disbursement will be recorded as Income (Green).\n• Periodic interest and principal repayments you pay will be Expense (Red).",
      icon: Icons.swap_horiz_rounded,
      onSubmitLabel: "Switch",
      onSubmit: () async {
        Navigator.of(context).pop();
        final updatedObj = widget.objective.copyWith(income: newIncome);
        await database.createOrUpdateObjective(updatedObj);

        final txs = await database.getAllTransactionsBelongingToObjective(
          widget.objective.objectivePk,
        );
        for (final tx in txs) {
          final isInitial = tx.name.toLowerCase().contains("initial") ||
              (tx.note != null && tx.note!.toLowerCase().contains("initial"));
          if (isInitial) {
            final expectedIncome = !newIncome;
            final expectedAmount = tx.amount.abs() * (expectedIncome ? 1 : -1);
            await database.createOrUpdateTransaction(
              tx.copyWith(
                income: expectedIncome,
                amount: expectedAmount,
              ),
              insert: false,
            );
          }
        }

        final config = InterestLoanManager.instance.getConfig(
          widget.objective.objectivePk,
        );
        if (config.isEnabled) {
          await InterestLoanManager.instance.syncUpcomingInterestTransaction(
            objective: updatedObj,
            config: config,
          );
        }

        InterestLoanManager.instance.notify();

        openSnackbar(
          SnackbarMessage(
            title: "Switched to $newLabel",
            description: "Loan accounting polarity updated successfully.",
            icon: Icons.check_circle_outline,
          ),
        );
      },
      onCancelLabel: "Cancel",
      onCancel: () {
        Navigator.of(context).pop();
      },
    );
  }

  void _showConfigureInterestDialog([
    List<Transaction>? currentTransactions,
    double? fallbackPrincipal,
  ]) {
    final currentConfig = InterestLoanManager.instance.getConfig(
      widget.objective.objectivePk,
      fallbackStartDate: widget.objective.dateCreated,
    );

    final rateController = TextEditingController(
      text: currentConfig.interestRate > 0
          ? currentConfig.interestRate.toString()
          : "",
    );
    LoanInterestPeriod selectedPeriod = currentConfig.period;
    bool enabled = currentConfig.isEnabled;
    DateTime selectedAnchorDate = currentConfig.anchorDate;

    openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: "Configure Loan Interest",
        subtitle:
            "Track periodic interest rates and automatically calculate upcoming amounts and next due dates.",
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final dateFormat = DateFormat('dd MMM yyyy');
            final parsedRate =
                double.tryParse(rateController.text.trim()) ?? 0.0;
            final previewConfig = InterestLoanConfig(
              objectivePk: widget.objective.objectivePk,
              interestRate: parsedRate,
              period: selectedPeriod,
              startDate: currentConfig.startDate,
              anchorDate: selectedAnchorDate,
              isEnabled: enabled,
            );

            final previewCalc = LoanInterestCalculationResult.calculate(
              objective: widget.objective,
              config: previewConfig,
              transactions: currentTransactions ?? [],
              fallbackPrincipal: fallbackPrincipal ?? 0.0,
            );

            String cycleNote;
            switch (selectedPeriod) {
              case LoanInterestPeriod.daily:
                cycleNote = "Calculates interest every single day";
                break;
              case LoanInterestPeriod.weekly:
                cycleNote =
                    "Calculates interest weekly on every ${DateFormat('EEEE').format(selectedAnchorDate)}";
                break;
              case LoanInterestPeriod.monthly:
                cycleNote =
                    "Calculates interest monthly on the ${selectedAnchorDate.day}${_getDaySuffix(selectedAnchorDate.day)} of each month";
                break;
              case LoanInterestPeriod.yearly:
                cycleNote =
                    "Calculates interest annually on ${DateFormat('dd MMMM').format(selectedAnchorDate)} (APR)";
                break;
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                // Enable Switch
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const TextFont(
                    text: "Enable Periodic Interest",
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  subtitle: TextFont(
                    text: enabled
                        ? "Interest tracking is active"
                        : "Turn on to calculate upcoming interest charges",
                    fontSize: 12,
                    textColor: getColor(context, "textLight"),
                  ),
                  value: enabled,
                  onChanged: (val) {
                    setDialogState(() {
                      enabled = val;
                    });
                  },
                ),
                const SizedBox(height: 10),

                // Interest Rate Input
                TextInput(
                  labelText: "Interest Rate (%)",
                  controller: rateController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: false,
                  ),
                  onChanged: (_) {
                    setDialogState(() {});
                  },
                  padding: const EdgeInsetsDirectional.only(bottom: 12),
                ),

                // Accrual Cycle Dropdown
                DropdownButtonFormField<LoanInterestPeriod>(
                  value: selectedPeriod,
                  decoration: const InputDecoration(
                    labelText: "Interest Accrual Cycle",
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  items: LoanInterestPeriod.values.map((p) {
                    String label = p.name.capitalizeFirst;
                    if (p == LoanInterestPeriod.yearly) label = "Annual (APR)";
                    return DropdownMenuItem(
                      value: p,
                      child: Text(label),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() {
                        selectedPeriod = val;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),

                // Anchor Date Selector
                TextFont(
                  text: "Interest Due Date / Anchor Date:",
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedAnchorDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        selectedAnchorDate = picked;
                      });
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: getColor(context, "dividerColor"),
                      ),
                      borderRadius: BorderRadius.circular(12),
                      color: getColor(context, "canvasContainer"),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.calendar_month_rounded,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            TextFont(
                              text: dateFormat.format(selectedAnchorDate),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ],
                        ),
                        TextFont(
                          text: "Change",
                          fontSize: 12,
                          textColor: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextFont(
                  text: cycleNote,
                  fontSize: 11,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 14),

                // Live Preview Card
                if (enabled && parsedRate > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withOpacity(0.35),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "Live Upcoming Calculation Preview",
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          textColor: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 4),
                        TextFont(
                          text:
                              "Upcoming ${previewConfig.periodLabel} Interest: ${_formatMoney(context, previewCalc.upcomingInterestAmount)}",
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text:
                              "Next Due: ${dateFormat.format(previewCalc.nextDueDate)}",
                          fontSize: 12,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 18),

                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(context, "canvasContainer"),
                        textColor: getColor(context, "black"),
                        onTap: () => Navigator.of(dialogContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Button(
                        label: "Save Configuration",
                        icon: Icons.check_circle_outline,
                        color: Theme.of(context).colorScheme.primary,
                        textColor: Theme.of(context).colorScheme.onPrimary,
                        onTap: () async {
                          final rate =
                              double.tryParse(rateController.text.trim()) ?? 0.0;
                          final newConfig = InterestLoanConfig(
                            objectivePk: widget.objective.objectivePk,
                            interestRate: rate,
                            period: selectedPeriod,
                            startDate: currentConfig.startDate,
                            anchorDate: selectedAnchorDate,
                            isEnabled: enabled,
                          );

                          await InterestLoanManager.instance.saveConfig(
                            newConfig,
                            objective: widget.objective,
                          );

                          Navigator.of(dialogContext).pop();
                          setState(() {});

                          openSnackbar(
                            SnackbarMessage(
                              title: "Interest Configuration Saved",
                              description: enabled
                                  ? "$rate% ${newConfig.perPeriodText} scheduled"
                                  : "Periodic interest disabled",
                              icon: Icons.check_circle_outline,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
      ),
    );
  }

  static String _getDaySuffix(int day) {
    if (day >= 11 && day <= 13) return "th";
    switch (day % 10) {
      case 1:
        return "st";
      case 2:
        return "nd";
      case 3:
        return "rd";
      default:
        return "th";
    }
  }

  Future<void> _showPayInterestDialog(
      LoanInterestCalculationResult calc, List<TransactionWallet> wallets) async {
    List<TransactionWallet> availableWallets = wallets;
    if (availableWallets.isEmpty) {
      availableWallets = await database.getAllWallets();
    }
    if (availableWallets.isEmpty) {
      openSnackbar(
        SnackbarMessage(
          title: "No Account Found",
          description: "Please create a wallet or account first.",
          icon: Icons.error_outline,
        ),
      );
      return;
    }

    final double pendingInterest = calc.accruedInterestDue > 0
        ? calc.accruedInterestDue
        : calc.upcomingInterestAmount;

    final amountController = TextEditingController(
      text: pendingInterest > 0 ? pendingInterest.toStringAsFixed(2) : "",
    );
    String selectedWalletPk = availableWallets.first.walletPk;

    openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: widget.objective.income ? "Collect Interest" : "Pay Interest",
        subtitle:
            "Services periodic interest charges. Current outstanding principal: ${_formatMoney(context, calc.currentPrincipal)}.",
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextInput(
                    labelText: "Interest Amount",
                    controller: amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: false),
                    padding: const EdgeInsetsDirectional.only(bottom: 12),
                  ),
                  DropdownButtonFormField<String>(
                    value: selectedWalletPk,
                    decoration: const InputDecoration(
                      labelText: "Account / Wallet",
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    items: availableWallets.map((w) {
                      return DropdownMenuItem(
                        value: w.walletPk,
                        child: Text(w.name),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() {
                          selectedWalletPk = val;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Button(
                          label: "Cancel",
                          color: getColor(context, "canvasContainer"),
                          textColor: getColor(context, "black"),
                          onTap: () => Navigator.of(dialogContext).pop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Button(
                          label: "Record Payment",
                          color: Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          onTap: () async {
                            final enteredAmt =
                                double.tryParse(amountController.text.trim()) ??
                                    0.0;
                            if (enteredAmt <= 0) return;

                            Navigator.of(dialogContext).pop();

                            // If amount paid is more than pending interest, ask to adjust with principal
                            if (pendingInterest > 0 &&
                                enteredAmt > pendingInterest + 0.01) {
                              final excess = enteredAmt - pendingInterest;
                              openPopup(
                                context,
                                title: "Adjust Excess with Principal?",
                                description:
                                    "Amount entered (${_formatMoney(context, enteredAmt)}) exceeds pending interest (${_formatMoney(context, pendingInterest)}) by ${_formatMoney(context, excess)}.\n\nShould the excess ${_formatMoney(context, excess)} be adjusted to reduce the outstanding loan principal?",
                                icon: Icons.swap_horiz_rounded,
                                onSubmitLabel: "Yes, Adjust Principal",
                                onSubmit: () async {
                                  Navigator.of(context).pop();
                                  await InterestLoanManager.instance
                                      .recordInterestPayment(
                                    objective: widget.objective,
                                    amount: pendingInterest,
                                    walletPk: selectedWalletPk,
                                    note: "Interest payment for cycle",
                                  );
                                  await InterestLoanManager.instance
                                      .recordPrincipalRepayment(
                                    objective: widget.objective,
                                    amount: excess,
                                    walletPk: selectedWalletPk,
                                    note:
                                        "Excess interest adjusted against principal",
                                  );
                                  openSnackbar(
                                    SnackbarMessage(
                                      title:
                                          "Payment Recorded & Principal Adjusted",
                                      description:
                                          "Interest: ${_formatMoney(context, pendingInterest)} | Principal Reduced by: ${_formatMoney(context, excess)}",
                                      icon: Icons.check_circle_outline,
                                    ),
                                  );
                                },
                                onCancelLabel: "No, Keep as Interest",
                                onCancel: () async {
                                  Navigator.of(context).pop();
                                  await InterestLoanManager.instance
                                      .recordInterestPayment(
                                    objective: widget.objective,
                                    amount: enteredAmt,
                                    walletPk: selectedWalletPk,
                                  );
                                  openSnackbar(
                                    SnackbarMessage(
                                      title: "Interest payment recorded",
                                      icon: Icons.check_circle_outline,
                                    ),
                                  );
                                },
                              );
                            } else if (pendingInterest <= 0) {
                              // If no interest is due, ask whether to adjust with principal
                              openPopup(
                                context,
                                title: "Apply to Principal?",
                                description:
                                    "No pending interest is due.\n\nShould this payment of ${_formatMoney(context, enteredAmt)} be applied to reduce the outstanding loan principal?",
                                icon: Icons.payments_rounded,
                                onSubmitLabel: "Yes, Reduce Principal",
                                onSubmit: () async {
                                  Navigator.of(context).pop();
                                  await InterestLoanManager.instance
                                      .recordPrincipalRepayment(
                                    objective: widget.objective,
                                    amount: enteredAmt,
                                    walletPk: selectedWalletPk,
                                    note: "Principal reduction payment",
                                  );
                                  openSnackbar(
                                    SnackbarMessage(
                                      title: "Principal balance reduced",
                                      description:
                                          "Paid: ${_formatMoney(context, enteredAmt)} towards principal",
                                      icon: Icons.check_circle_outline,
                                    ),
                                  );
                                },
                                onCancelLabel: "No, Record as Interest",
                                onCancel: () async {
                                  Navigator.of(context).pop();
                                  await InterestLoanManager.instance
                                      .recordInterestPayment(
                                    objective: widget.objective,
                                    amount: enteredAmt,
                                    walletPk: selectedWalletPk,
                                    note: "Advance interest payment",
                                  );
                                  openSnackbar(
                                    SnackbarMessage(
                                      title: "Interest payment recorded",
                                      icon: Icons.check_circle_outline,
                                    ),
                                  );
                                },
                              );
                            } else {
                              await InterestLoanManager.instance
                                  .recordInterestPayment(
                                objective: widget.objective,
                                amount: enteredAmt,
                                walletPk: selectedWalletPk,
                              );
                              openSnackbar(
                                SnackbarMessage(
                                  title:
                                      "Interest payment recorded (Principal unchanged)",
                                  icon: Icons.check_circle_outline,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showPayPartPrincipalDialog(
      LoanInterestCalculationResult calc, List<TransactionWallet> wallets) async {
    List<TransactionWallet> availableWallets = wallets;
    if (availableWallets.isEmpty) {
      availableWallets = await database.getAllWallets();
    }
    if (availableWallets.isEmpty) {
      openSnackbar(
        SnackbarMessage(
          title: "No Account Found",
          description: "Please create a wallet or account first.",
          icon: Icons.error_outline,
        ),
      );
      return;
    }

    final amountController = TextEditingController();
    String selectedWalletPk = availableWallets.first.walletPk;

    openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: widget.objective.income
            ? "Collect Part-Principal"
            : "Pay Part-Principal",
        subtitle:
            "Reduces the outstanding principal from ${_formatMoney(context, calc.currentPrincipal)}. Future interest will be calculated on the lower remaining balance.",
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                TextInput(
                  labelText: "Part-Payment Amount",
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: false),
                  padding: const EdgeInsetsDirectional.only(bottom: 12),
                ),
                DropdownButtonFormField<String>(
                  value: selectedWalletPk,
                  decoration: const InputDecoration(
                    labelText: "Account / Wallet",
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  items: availableWallets.map((w) {
                    return DropdownMenuItem(
                      value: w.walletPk,
                      child: Text(w.name),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() {
                        selectedWalletPk = val;
                      });
                    }
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(context, "canvasContainer"),
                        textColor: getColor(context, "black"),
                        onTap: () => Navigator.of(dialogContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Button(
                        label: "Reduce Principal",
                        color: Theme.of(context).colorScheme.primary,
                        textColor: Theme.of(context).colorScheme.onPrimary,
                        onTap: () async {
                          final enteredAmt =
                              double.tryParse(amountController.text.trim()) ??
                                  0.0;
                          if (enteredAmt <= 0) return;

                          Navigator.of(dialogContext).pop();

                          await InterestLoanManager.instance
                              .recordPrincipalRepayment(
                            objective: widget.objective,
                            amount: enteredAmt,
                            walletPk: selectedWalletPk,
                          );

                          openSnackbar(
                            SnackbarMessage(
                              title: "Principal balance reduced successfully!",
                              description:
                                  "Paid: ${_formatMoney(context, enteredAmt)} towards principal",
                              icon: Icons.check_circle_outline,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: InterestLoanManager.instance,
      builder: (context, _) {
        final config = InterestLoanManager.instance.getConfig(
          widget.objective.objectivePk,
          fallbackStartDate: widget.objective.dateCreated,
        );

        return StreamBuilder<double?>(
          stream: database.watchTotalAmountObjectiveLoan(
              Provider.of<AllWallets>(context), widget.objective),
          builder: (context, loanTotalSnapshot) {
            final loanTotalFromDb = loanTotalSnapshot.data ?? 0.0;

            return StreamBuilder<List<Transaction>>(
              stream: database.watchAllTransactionsBelongingToObjective(
                  widget.objective.objectivePk),
              builder: (context, snapshot) {
                final transactions = snapshot.data ?? [];
                final calc = LoanInterestCalculationResult.calculate(
                  objective: widget.objective,
                  config: config,
                  transactions: transactions,
                  fallbackPrincipal: loanTotalFromDb,
                );

            return StreamBuilder<List<TransactionWallet>>(
              stream: database.watchAllWallets(),
              builder: (context, walletSnapshot) {
                final wallets = walletSnapshot.data ?? [];
                final dateFormat = DateFormat('dd MMM yyyy');

                final daysDiff =
                    calc.nextDueDate.difference(DateTime.now()).inDays;
                String dueBadgeText;
                Color dueBadgeColor;

                if (daysDiff < 0) {
                  dueBadgeText = widget.objective.income
                      ? "Overdue Collect (${daysDiff.abs()}d)"
                      : "Overdue Pay (${daysDiff.abs()}d)";
                  dueBadgeColor = Colors.red;
                } else if (daysDiff == 0) {
                  dueBadgeText = "Due Today";
                  dueBadgeColor = Colors.orange;
                } else if (daysDiff == 1) {
                  dueBadgeText = "Due Tomorrow";
                  dueBadgeColor = Colors.blue;
                } else {
                  dueBadgeText = widget.objective.income
                      ? "Collect in $daysDiff d"
                      : "Pay in $daysDiff d";
                  dueBadgeColor = widget.objective.income
                      ? getColor(context, "incomeAmount")
                      : getColor(context, "expenseAmount");
                }

                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color:
                            theme.colorScheme.outlineVariant.withOpacity(0.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header with Loan Polarity Badge & Configure Button
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: (widget.objective.income
                                              ? getColor(context, "incomeAmount")
                                              : getColor(context, "expenseAmount"))
                                          .withOpacity(0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.percent_rounded,
                                      size: 20,
                                      color: widget.objective.income
                                          ? getColor(context, "incomeAmount")
                                          : getColor(context, "expenseAmount"),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        TextFont(
                                          text: "Interest & Principal Tracker",
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        TextFont(
                                          text: config.isEnabled
                                              ? "${config.interestRate}% ${config.perPeriodText} (${config.periodLabel})"
                                              : "Periodic interest is disabled",
                                          fontSize: 12,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textColor:
                                              getColor(context, "textLight"),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.tune_rounded, size: 22),
                              onPressed: () =>
                                  _showConfigureInterestDialog(transactions, loanTotalFromDb),
                              tooltip: "Configure Interest",
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Interactive Loan Polarity Switcher Pill
                        InkWell(
                          onTap: _toggleLoanType,
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: (widget.objective.income
                                      ? getColor(context, "incomeAmount")
                                      : getColor(context, "expenseAmount"))
                                  .withOpacity(0.12),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: (widget.objective.income
                                        ? getColor(context, "incomeAmount")
                                        : getColor(context, "expenseAmount"))
                                    .withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  widget.objective.income
                                      ? Icons.arrow_downward_rounded
                                      : Icons.arrow_upward_rounded,
                                  size: 15,
                                  color: widget.objective.income
                                      ? getColor(context, "incomeAmount")
                                      : getColor(context, "expenseAmount"),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: TextFont(
                                    text: widget.objective.income
                                        ? "Lent Loan (Credit) • Receive Interest as Income"
                                        : "Borrowed Loan (Debt) • Pay Interest as Expense",
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    textColor: widget.objective.income
                                        ? getColor(context, "incomeAmount")
                                        : getColor(context, "expenseAmount"),
                                  ),
                                ),
                                Icon(
                                  Icons.swap_horiz_rounded,
                                  size: 16,
                                  color: widget.objective.income
                                      ? getColor(context, "incomeAmount")
                                      : getColor(context, "expenseAmount"),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 20),

                        // Upcoming Interest Card (Shows upcoming interest amount and next due date)
                        if (config.isEnabled && config.interestRate > 0) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  (widget.objective.income
                                          ? getColor(context, "incomeAmount")
                                          : getColor(context, "expenseAmount"))
                                      .withOpacity(0.12),
                                  theme.colorScheme.surfaceVariant
                                      .withOpacity(0.2),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: (widget.objective.income
                                        ? getColor(context, "incomeAmount")
                                        : getColor(context, "expenseAmount"))
                                    .withOpacity(0.25),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.upcoming_rounded,
                                      size: 16,
                                      color: widget.objective.income
                                          ? getColor(context, "incomeAmount")
                                          : getColor(context, "expenseAmount"),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: TextFont(
                                        text:
                                            "Upcoming ${config.periodLabel} Interest (${widget.objective.income ? "To Collect" : "To Pay"})",
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textColor: widget.objective.income
                                            ? getColor(context, "incomeAmount")
                                            : getColor(context, "expenseAmount"),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: dueBadgeColor.withOpacity(0.12),
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: TextFont(
                                        text: dueBadgeText,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        textColor: dueBadgeColor,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Expanded(
                                      child: TextFont(
                                        text: _formatMoney(context,
                                            calc.upcomingInterestAmount),
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textColor: widget.objective.income
                                            ? getColor(context, "incomeAmount")
                                            : getColor(context, "expenseAmount"),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.event_rounded,
                                          size: 14,
                                          color: getColor(
                                              context, "textLight"),
                                        ),
                                        const SizedBox(width: 4),
                                        TextFont(
                                          text: dateFormat
                                              .format(calc.nextDueDate),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          textColor: getColor(
                                              context, "textLight"),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          // All 4 Cycles Rate Breakdown (Daily, Weekly, Monthly, Annual)
                          TextFont(
                            text: "Equivalent Accrual Rates:",
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            textColor: getColor(context, "textLight"),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              _buildCycleRatePill(
                                context,
                                label: "Daily",
                                amount: _formatMoney(
                                    context, calc.dailyInterestAmount),
                                isSelected:
                                    config.period == LoanInterestPeriod.daily,
                              ),
                              const SizedBox(width: 6),
                              _buildCycleRatePill(
                                context,
                                label: "Weekly",
                                amount: _formatMoney(
                                    context, calc.weeklyInterestAmount),
                                isSelected:
                                    config.period == LoanInterestPeriod.weekly,
                              ),
                              const SizedBox(width: 6),
                              _buildCycleRatePill(
                                context,
                                label: "Monthly",
                                amount: _formatMoney(
                                    context, calc.monthlyInterestAmount),
                                isSelected:
                                    config.period == LoanInterestPeriod.monthly,
                              ),
                              const SizedBox(width: 6),
                              _buildCycleRatePill(
                                context,
                                label: "Annual",
                                amount: _formatMoney(
                                    context, calc.annualInterestAmount),
                                isSelected:
                                    config.period == LoanInterestPeriod.yearly,
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                        ],

                        // Metrics Grid: Principal & Accrued Interest Due
                        Row(
                          children: [
                            // Outstanding Principal
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceVariant
                                      .withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    TextFont(
                                      text: "Outstanding Principal",
                                      fontSize: 11,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textColor: getColor(context, "textLight"),
                                    ),
                                    const SizedBox(height: 4),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: AlignmentDirectional.centerStart,
                                      child: TextFont(
                                        text: _formatMoney(
                                            context, calc.currentPrincipal),
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: AlignmentDirectional.centerStart,
                                      child: TextFont(
                                        text:
                                            "Orig: ${_formatMoney(context, calc.originalPrincipal)}",
                                        fontSize: 10,
                                        textColor: getColor(context, "textLight"),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),

                            // Accrued Interest Due
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: calc.accruedInterestDue > 0
                                      ? Colors.amber.withOpacity(0.12)
                                      : theme.colorScheme.surfaceVariant
                                          .withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    TextFont(
                                      text: "Accrued Interest Due",
                                      fontSize: 11,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textColor: getColor(context, "textLight"),
                                    ),
                                    const SizedBox(height: 4),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: AlignmentDirectional.centerStart,
                                      child: TextFont(
                                        text: _formatMoney(
                                            context, calc.accruedInterestDue),
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        textColor: calc.accruedInterestDue > 0
                                            ? Colors.amber.shade900
                                            : null,
                                      ),
                                    ),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: AlignmentDirectional.centerStart,
                                      child: TextFont(
                                        text:
                                            "Paid: ${_formatMoney(context, calc.totalInterestPaid)}",
                                        fontSize: 10,
                                        textColor: getColor(context, "textLight"),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Action Buttons: Pay/Collect Interest & Part-Principal
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  foregroundColor: widget.objective.income
                                      ? getColor(context, "incomeAmount")
                                      : getColor(context, "expenseAmount"),
                                  side: BorderSide(
                                    color: (widget.objective.income
                                            ? getColor(context, "incomeAmount")
                                            : getColor(context, "expenseAmount"))
                                        .withOpacity(0.5),
                                  ),
                                ),
                                icon: Icon(
                                    widget.objective.income
                                        ? Icons.arrow_downward_rounded
                                        : Icons.arrow_upward_rounded,
                                    size: 18),
                                label: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(widget.objective.income
                                      ? "Collect Interest"
                                      : "Pay Interest"),
                                ),
                                onPressed: () =>
                                    _showPayInterestDialog(calc, wallets),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  backgroundColor: widget.objective.income
                                      ? getColor(context, "incomeAmount")
                                      : getColor(context, "expenseAmount"),
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.payments_rounded,
                                    size: 18),
                                label: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(widget.objective.income
                                      ? "Receive Principal"
                                      : "Part-Principal"),
                                ),
                                onPressed: () => _showPayPartPrincipalDialog(
                                    calc, wallets),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  },
);
  }

  Widget _buildCycleRatePill(
    BuildContext context, {
    required String label,
    required String amount,
    required bool isSelected,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceVariant.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TextFont(
                text: label,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                textColor: isSelected
                    ? theme.colorScheme.primary
                    : getColor(context, "textLight"),
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TextFont(
                text: amount,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
