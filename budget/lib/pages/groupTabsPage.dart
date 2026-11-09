import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/groupTabDetailPage.dart';
import 'package:budget/struct/groupTabs/groupTabManager.dart';
import 'package:budget/struct/groupTabs/groupTabModels.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class GroupTabsPage extends StatefulWidget {
  const GroupTabsPage({Key? key}) : super(key: key);

  @override
  State<GroupTabsPage> createState() => _GroupTabsPageState();
}

class _GroupTabsPageState extends State<GroupTabsPage> {
  @override
  void initState() {
    super.initState();
    GroupTabManager.instance.init().then((_) {
      if (mounted) setState(() {});
    });
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

  void _showCreateGroupModal() {
    final nameController = TextEditingController();
    final membersController = TextEditingController(text: "Alice, Bob");

    openBottomSheet(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TextFont(
              text: "Create Shared Group Tab",
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            const SizedBox(height: 8),
            TextFont(
              text:
                  "Track group balances for flatmates, trips, or shared expenses.",
              fontSize: 13,
              textColor: getColor(context, "textLight"),
            ),
            const SizedBox(height: 14),
            TextInput(
              controller: nameController,
              labelText: "Group Name (e.g. Goa Trip, Flat 402)",
              bubbly: false,
              padding: const EdgeInsetsDirectional.all(12),
            ),
            const SizedBox(height: 10),
            TextInput(
              controller: membersController,
              labelText: "Members (comma separated names)",
              bubbly: false,
              padding: const EdgeInsetsDirectional.all(12),
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
                    label: "Create Group",
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    onTap: () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) return;
                      final rawMembers = membersController.text.split(',');
                      Navigator.of(context).pop();

                      final newGroup =
                          await GroupTabManager.instance.createGroup(
                        name: name,
                        members: rawMembers,
                      );

                      pushRoute(
                        context,
                        GroupTabDetailPage(groupTabId: newGroup.id),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = GroupTabManager.instance.tabs;
    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[appStateSettings["selectedWalletPk"]]?.currency ??
        "";

    return PageFramework(
      title: "Group Tabs",
      actions: [
        IconButton(
          tooltip: "New Group Tab",
          icon: const Icon(Icons.add_rounded),
          onPressed: _showCreateGroupModal,
        ),
      ],
      listWidgets: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: getColor(context, "canvasContainer"),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: getColor(context, "dividerColor").withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.groups_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const TextFont(
                        text: "Shared Group Expenses",
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      const SizedBox(height: 2),
                      TextFont(
                        text: "Split bills & settle with minimum transactions",
                        fontSize: 12,
                        textColor: getColor(context, "textLight"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        if (tabs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60.0, horizontal: 24),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.group_work_rounded,
                    size: 64,
                    color: getColor(context, "textLight").withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  const TextFont(
                    text: "No Group Tabs Yet",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  const SizedBox(height: 8),
                  TextFont(
                    text:
                        "Create a group tab to split shared expenses with friends or flatmates, simplify debts, and settle directly to your accounts.",
                    textAlign: TextAlign.center,
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                  const SizedBox(height: 20),
                  Button(
                    label: "+ Create Group Tab",
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    onTap: _showCreateGroupModal,
                  ),
                ],
              ),
            ),
          )
        else
          ...tabs.map((tab) {
            final expenses =
                GroupTabManager.instance.getExpensesForTab(tab.id);
            final transfers = DebtSimplifier.simplify(
              expenses: expenses,
              members: tab.members,
            );

            // Compute user's net status in this tab
            double youNet = 0.0;
            for (final t in transfers) {
              if (t.toPerson == "You") youNet += t.amount;
              if (t.fromPerson == "You") youNet -= t.amount;
            }

            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
              child: InkWell(
                onTap: () {
                  pushRoute(
                    context,
                    GroupTabDetailPage(groupTabId: tab.id),
                  );
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: getColor(context, "canvasContainer"),
                    borderRadius: BorderRadius.circular(16),
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
                              text: tab.name,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            const SizedBox(height: 4),
                            TextFont(
                              text:
                                  "${tab.members.length} members  •  ${expenses.length} expenses",
                              fontSize: 12,
                              textColor: getColor(context, "textLight"),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (youNet.abs() <= 0.01)
                            const TextFont(
                              text: "Settled",
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              textColor: Colors.green,
                            )
                          else if (youNet > 0)
                            TextFont(
                              text: "+ $currency${youNet.toStringAsFixed(2)}",
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              textColor: Colors.green,
                            )
                          else
                            TextFont(
                              text: "- $currency${youNet.abs().toStringAsFixed(2)}",
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              textColor: Colors.redAccent,
                            ),
                          TextFont(
                            text: youNet.abs() <= 0.01
                                ? "No dues"
                                : (youNet > 0 ? "You are owed" : "You owe"),
                            fontSize: 11,
                            textColor: getColor(context, "textLight"),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),

        const SizedBox(height: 40),
      ],
    );
  }
}
