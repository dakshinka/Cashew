import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/groupTabs/groupTabManager.dart';
import 'package:budget/struct/groupTabs/groupTabModels.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class GroupTabDetailPage extends StatefulWidget {
  final String groupTabId;

  const GroupTabDetailPage({Key? key, required this.groupTabId})
      : super(key: key);

  @override
  State<GroupTabDetailPage> createState() => _GroupTabDetailPageState();
}

class _GroupTabDetailPageState extends State<GroupTabDetailPage> {
  @override
  void initState() {
    super.initState();
    GroupTabManager.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    GroupTabManager.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _showAddExpenseModal(GroupTab tab) {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    String payer = "You";
    final selectedMembers = Set<String>.from(tab.members);

    openBottomSheet(
      context,
      StatefulBuilder(
        builder: (ctx, setModalState) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFont(
                  text: "Add Group Expense",
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                const SizedBox(height: 12),
                TextInput(
                  controller: titleController,
                  labelText: "Expense Description (e.g. Dinner, Cab)",
                  bubbly: false,
                  padding: const EdgeInsetsDirectional.all(12),
                ),
                const SizedBox(height: 10),
                TextInput(
                  controller: amountController,
                  labelText: "Total Amount",
                  bubbly: false,
                  padding: const EdgeInsetsDirectional.all(12),
                ),
                const SizedBox(height: 12),
                TextFont(
                  text: "Paid By:",
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: tab.members.map((m) {
                    final isPayer = m == payer;
                    return ChoiceChip(
                      label: TextFont(text: m, fontSize: 12),
                      selected: isPayer,
                      onSelected: (val) {
                        if (val) setModalState(() => payer = m);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextFont(
                  text: "Split Equally Among:",
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: tab.members.map((m) {
                    final isIncluded = selectedMembers.contains(m);
                    return FilterChip(
                      label: TextFont(text: m, fontSize: 12),
                      selected: isIncluded,
                      onSelected: (val) {
                        setModalState(() {
                          if (val) {
                            selectedMembers.add(m);
                          } else if (selectedMembers.length > 1) {
                            selectedMembers.remove(m);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(context, "canvasContainer"),
                        textColor: getColor(context, "black"),
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Button(
                        label: "Save Expense",
                        color: Theme.of(context).colorScheme.primary,
                        textColor: Theme.of(context).colorScheme.onPrimary,
                        onTap: () async {
                          final title = titleController.text.trim();
                          final amt =
                              double.tryParse(amountController.text.trim()) ??
                                  0.0;
                          if (title.isEmpty || amt <= 0) return;

                          Navigator.of(context).pop();

                          final sharePerPerson = amt / selectedMembers.length;
                          final Map<String, double> shares = {};
                          for (final m in selectedMembers) {
                            shares[m] = sharePerPerson;
                          }

                          await GroupTabManager.instance.addExpense(
                            groupTabId: tab.id,
                            title: title,
                            amount: amt,
                            paidBy: payer,
                            splitShares: shares,
                          );

                          openSnackbar(
                            SnackbarMessage(
                              title: "Expense Added",
                              description: "$title ($amt split among ${shares.length})",
                              icon: Icons.check_circle_outline,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showSettleTransferDialog(
      DebtSimplificationTransfer transfer, List<TransactionWallet> wallets) {
    if (wallets.isEmpty) return;
    String selectedWalletPk = wallets.first.walletPk;

    final isYouPaying = transfer.fromPerson == "You";

    openPopup(
      context,
      title: isYouPaying ? "Settle Payment" : "Record Settlement",
      description: isYouPaying
          ? "Pay ${transfer.toPerson} \$${transfer.amount.toStringAsFixed(2)} to settle your share."
          : "Receive \$${transfer.amount.toStringAsFixed(2)} from ${transfer.fromPerson}.",
      icon: Icons.account_balance_wallet_outlined,
      onSubmitLabel: isYouPaying ? "Pay & Record" : "Mark Received",
      onSubmit: () async {
        final success = await GroupTabManager.instance.settleTransfer(
          groupTabId: widget.groupTabId,
          transfer: transfer,
          walletPk: selectedWalletPk,
        );

        if (success) {
          openSnackbar(
            SnackbarMessage(
              title: "Settlement Recorded",
              description:
                  "${transfer.fromPerson} settled with ${transfer.toPerson}",
              icon: Icons.check_circle_outline,
            ),
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = GroupTabManager.instance.getTab(widget.groupTabId);
    if (tab == null) {
      return PageFramework(
        title: "Group Tab",
        listWidgets: const [Center(child: TextFont(text: "Group not found"))],
      );
    }

    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[appStateSettings["selectedWalletPk"]]?.currency ??
        "";
    final wallets = Provider.of<AllWallets>(context).list;

    final expenses =
        GroupTabManager.instance.getExpensesForTab(widget.groupTabId);
    final simplifiedTransfers = DebtSimplifier.simplify(
      expenses: expenses,
      members: tab.members,
    );

    return PageFramework(
      title: tab.name,
      actions: [
        IconButton(
          tooltip: "Add Expense",
          icon: const Icon(Icons.add_rounded),
          onPressed: () => _showAddExpenseModal(tab),
        ),
      ],
      listWidgets: [
        // Group Members Chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: tab.members.map((m) {
              return Chip(
                avatar: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: TextFont(
                    text: m[0].toUpperCase(),
                    fontSize: 11,
                    textColor: Colors.white,
                  ),
                ),
                label: TextFont(text: m, fontSize: 12),
              );
            }).toList(),
          ),
        ),

        // Debt Simplification Settlement Box
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: getColor(context, "canvasContainer"),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: getColor(context, "dividerColor").withOpacity(0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.insights_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const TextFont(
                      text: "Simplified Settlement Plan",
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextFont(
                  text:
                      "Minimizes transactions to settle all debts with zero unnecessary transfers.",
                  fontSize: 12,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 12),
                if (simplifiedTransfers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_rounded,
                            color: Colors.green, size: 18),
                        const SizedBox(width: 8),
                        const TextFont(
                          text: "All settled up! No outstanding balances.",
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ],
                    ),
                  )
                else
                  ...simplifiedTransfers.map((t) {
                    final involvesYou =
                        t.fromPerson == "You" || t.toPerson == "You";
                    final youOwe = t.fromPerson == "You";

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextFont(
                              text:
                                  "${t.fromPerson} owes ${t.toPerson} $currency${t.amount.toStringAsFixed(2)}",
                              fontSize: 14,
                              fontWeight: involvesYou
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              textColor: involvesYou
                                  ? (youOwe ? Colors.redAccent : Colors.green)
                                  : getColor(context, "black"),
                            ),
                          ),
                          if (involvesYou)
                            Button(
                              label: youOwe ? "Settle" : "Mark Paid",
                              color: youOwe
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.green,
                              textColor: Colors.white,
                              padding: const EdgeInsetsDirectional.symmetric(
                                  horizontal: 10, vertical: 4),
                              fontSize: 11,
                              onTap: () =>
                                  _showSettleTransferDialog(t, wallets),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Row(
            children: [
              const TextFont(
                text: "Shared Expenses",
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const TextFont(text: "Add Expense", fontSize: 13),
                onPressed: () => _showAddExpenseModal(tab),
              ),
            ],
          ),
        ),

        // Expenses List
        if (expenses.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40.0, horizontal: 24),
            child: Center(
              child: TextFont(
                text: "No expenses added yet in this group.",
                fontSize: 14,
                textColor: getColor(context, "textLight"),
              ),
            ),
          )
        else
          ...expenses.map((exp) {
            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: getColor(context, "canvasContainer"),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: getColor(context, "dividerColor").withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFont(
                            text: exp.title,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          const SizedBox(height: 2),
                          TextFont(
                            text:
                                "Paid by ${exp.paidBy} on ${DateFormat('dd MMM').format(exp.date)}",
                            fontSize: 12,
                            textColor: getColor(context, "textLight"),
                          ),
                        ],
                      ),
                    ),
                    TextFont(
                      text: "$currency${exp.amount.toStringAsFixed(2)}",
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      color: getColor(context, "textLight"),
                      onPressed: () async {
                        await GroupTabManager.instance.deleteExpense(exp.id);
                      },
                    ),
                  ],
                ),
              ),
            );
          }).toList(),

        const SizedBox(height: 40),
      ],
    );
  }
}
