import 'package:flutter/material.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/pages/dailyServiceDetailPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/vendorTabs/vendorTabManager.dart';
import 'package:budget/struct/vendorTabs/vendorTabModels.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class VendorTabsPage extends StatefulWidget {
  const VendorTabsPage({Key? key}) : super(key: key);

  @override
  State<VendorTabsPage> createState() => _VendorTabsPageState();
}

class _VendorTabsPageState extends State<VendorTabsPage> {
  @override
  void initState() {
    super.initState();
    VendorTabManager.instance.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  String getCurrencyString(double amount) {
    return "\$${amount.toStringAsFixed(2)}";
  }

  void _showAddServiceDialog(List<TransactionWallet> wallets) {
    if (wallets.isEmpty) {
      openPopup(
        context,
        title: "No Accounts Found",
        description: "Please create a Vendor Tab account first.",
        onSubmitLabel: "OK",
        onSubmit: () => popRoute(context),
      );
      return;
    }

    final nameController = TextEditingController(text: "Daily Milk Delivery");
    final unitController = TextEditingController(text: "L");
    final rateController = TextEditingController(text: "35");
    final qtyController = TextEditingController(text: "1");
    String selectedWalletPk = wallets.first.walletPk;

    openPopup(
      context,
      title: "New Daily Service",
      description:
          "Set up a daily recurring delivery with variable rates (e.g. Milk, Newspaper, Water Cans):",
      onSubmitLabel: "Create Service",
      onSubmit: () async {
        final name = nameController.text.trim();
        final unit = unitController.text.trim();
        final rate = double.tryParse(rateController.text.trim()) ?? 0.0;
        final qty = double.tryParse(qtyController.text.trim()) ?? 1.0;

        if (name.isEmpty || rate <= 0) return;

        final service = DailyDeliveryService(
          name: name,
          unitName: unit.isEmpty ? "unit" : unit,
          defaultDailyQuantity: qty,
          vendorTabWalletPk: selectedWalletPk,
          ratePeriods: [
            RateSchedulePeriod(
              startDate: DateTime(DateTime.now().year, DateTime.now().month, 1),
              endDate: null,
              unitPrice: rate,
              unitName: unit.isEmpty ? "unit" : unit,
            ),
          ],
        );

        await VendorTabManager.instance.saveService(service);
        setState(() {});
        popRoute(context);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context),
      beforeDescriptionWidget: StatefulBuilder(
        builder: (context, setDialogState) {
          return Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                TextInput(
                  labelText: "Service Name",
                  controller: nameController,
                  padding: const EdgeInsetsDirectional.only(bottom: 10),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextInput(
                        labelText: "Unit (e.g. L, can, pkt)",
                        controller: unitController,
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextInput(
                        labelText: "Daily Qty",
                        controller: qtyController,
                        numbersOnly: true,
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                      ),
                    ),
                  ],
                ),
                TextInput(
                  labelText: "Initial Rate / Unit",
                  controller: rateController,
                  numbersOnly: true,
                  padding: const EdgeInsetsDirectional.only(bottom: 10),
                ),
                DropdownButtonFormField<String>(
                  value: selectedWalletPk,
                  decoration: const InputDecoration(
                    labelText: "Link to Vendor Tab Account",
                    border: OutlineInputBorder(),
                  ),
                  items: wallets.map((w) {
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
                const SizedBox(height: 10),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();

    return StreamBuilder<List<TransactionWallet>>(
      stream: database.watchAllWallets(),
      builder: (context, snapshot) {
        final wallets = snapshot.data ?? [];
        final services = VendorTabManager.instance.services;

        return PageFramework(
          title: "Vendor Tabs & Deliveries",
          dragDownToDismiss: true,
          listWidgets: [
            // Header Description
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.15),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.storefront_rounded,
                        size: 32, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFont(
                            text: "Running Store Tabs & Deliveries",
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          TextFont(
                            text:
                                "Track local store purchases (Khata) and recurring deliveries with price changes.",
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

            // Section 1: Daily Recurring Services (Milk, etc.)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextFont(
                    text: "Daily Delivery Services",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text("New Service"),
                    onPressed: () => _showAddServiceDialog(wallets),
                  ),
                ],
              ),
            ),

            if (services.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: TextFont(
                      text:
                          "No daily services set up yet.\nTap 'New Service' to track Milk, Newspaper, or Tiffin with mid-month rate changes.",
                      textAlign: TextAlign.center,
                      fontSize: 13,
                      textColor: getColor(context, "textLight"),
                    ),
                  ),
                ),
              )
            else
              for (final service in services) ...[
                Builder(builder: (context) {
                  final summary =
                      service.calculateMonth(now.year, now.month);
                  final activePrice = service.getPriceForDate(now);

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    child: InkWell(
                      onTap: () {
                        pushRoute(
                          context,
                          DailyServiceDetailPage(servicePk: service.servicePk),
                        ).then((_) => setState(() {}));
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant
                                .withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.local_shipping_rounded,
                                  color: theme.colorScheme.primary),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextFont(
                                    text: service.name,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  const SizedBox(height: 2),
                                  TextFont(
                                    text:
                                        "${service.defaultDailyQuantity} ${service.unitName}/day • Current Rate: ${getCurrencyString(activePrice)}",
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
                                  text: getCurrencyString(summary.totalCost),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  textColor: theme.colorScheme.primary,
                                ),
                                TextFont(
                                  text: "${summary.deliveredDays} delivered",
                                  fontSize: 11,
                                  textColor: Colors.green.shade700,
                                ),
                              ],
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],

            // Section 2: Store Running Tabs / Khatas
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextFont(
                    text: "Store Tabs / Khatas",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text("New Tab"),
                    onPressed: () {
                      pushRoute(
                        context,
                        AddWalletPage(
                          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            for (final wallet in wallets) ...[
              StreamBuilder<double?>(
                stream: database.watchTotalOfWalletNoConversion(wallet.walletPk),
                builder: (context, totalSnapshot) {
                  final rawBalance = totalSnapshot.data ?? 0.0;
                  final isOwed = rawBalance < 0;

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isOwed
                              ? Colors.red.withOpacity(0.3)
                              : theme.colorScheme.outlineVariant.withOpacity(0.4),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: isOwed
                                      ? Colors.red.withOpacity(0.12)
                                      : theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  isOwed
                                      ? Icons.receipt_long_rounded
                                      : Icons.account_balance_wallet_rounded,
                                  color: isOwed
                                      ? Colors.red
                                      : theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextFont(
                                      text: wallet.name,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    TextFont(
                                      text: isOwed
                                          ? "Outstanding Due to Store"
                                          : "Current Balance",
                                      fontSize: 12,
                                      textColor: isOwed
                                          ? Colors.red
                                          : getColor(context, "textLight"),
                                    ),
                                  ],
                                ),
                              ),
                              TextFont(
                                text: getCurrencyString(rawBalance.abs()),
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                textColor: isOwed ? Colors.red : null,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.add_shopping_cart_rounded,
                                      size: 16),
                                  label: const Text("+ Buy on Tab"),
                                  onPressed: () {
                                    pushRoute(
                                      context,
                                      AddTransactionPage(
                                        routesToPopAfterDelete:
                                            RoutesToPopAfterDelete.None,
                                        selectedWallet: wallet,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.payments_rounded,
                                      size: 16),
                                  label: const Text("Settle Tab"),
                                  onPressed: () {
                                    openBottomSheet(
                                      context,
                                      TransferBalancePopup(
                                        wallet: wallet,
                                        allowEditWallet: true,
                                        initialAmount:
                                            isOwed ? rawBalance.abs() : 0.0,
                                        initialTitle: "Settle ${wallet.name}",
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 30),
          ],
        );
      },
    );
  }
}
