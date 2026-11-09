import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/receiptVault/receiptManager.dart';
import 'package:budget/struct/receiptVault/receiptModels.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class ReceiptVaultPage extends StatefulWidget {
  const ReceiptVaultPage({Key? key}) : super(key: key);

  @override
  State<ReceiptVaultPage> createState() => _ReceiptVaultPageState();
}

class _ReceiptVaultPageState extends State<ReceiptVaultPage> {
  @override
  void initState() {
    super.initState();
    ReceiptManager.instance.init().then((_) {
      if (mounted) setState(() {});
    });
    ReceiptManager.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    ReceiptManager.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _showAddReceiptModal() {
    final titleController = TextEditingController();
    final storeController = TextEditingController();
    final priceController = TextEditingController();
    final notesController = TextEditingController();
    DateTime purchaseDate = DateTime.now();
    int? warrantyMonths = 12;

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
                const TextFont(
                  text: "Add Receipt & Warranty",
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                const SizedBox(height: 12),
                TextInput(
                  controller: titleController,
                  labelText: "Item Name (e.g. MacBook Pro, Shoes)",
                  bubbly: false,
                  padding: const EdgeInsetsDirectional.all(12),
                ),
                const SizedBox(height: 10),
                TextInput(
                  controller: storeController,
                  labelText: "Store / Merchant (e.g. Apple Store, Nike)",
                  bubbly: false,
                  padding: const EdgeInsetsDirectional.all(12),
                ),
                const SizedBox(height: 10),
                TextInput(
                  controller: priceController,
                  labelText: "Price Paid",
                  bubbly: false,
                  padding: const EdgeInsetsDirectional.all(12),
                ),
                const SizedBox(height: 12),
                TextFont(
                  text: "Warranty Duration:",
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [null, 6, 12, 24, 36].map((months) {
                    final isSelected = warrantyMonths == months;
                    return ChoiceChip(
                      label: TextFont(
                        text: months == null ? "None" : "$months Mos",
                        fontSize: 12,
                      ),
                      selected: isSelected,
                      onSelected: (val) {
                        if (val) setModalState(() => warrantyMonths = months);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                TextInput(
                  controller: notesController,
                  labelText: "Notes / Serial No.",
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
                        label: "Save Receipt",
                        color: Theme.of(context).colorScheme.primary,
                        textColor: Theme.of(context).colorScheme.onPrimary,
                        onTap: () async {
                          final title = titleController.text.trim();
                          final store = storeController.text.trim();
                          final price =
                              double.tryParse(priceController.text.trim()) ??
                                  0.0;
                          if (title.isEmpty || price <= 0) return;

                          Navigator.of(context).pop();

                          DateTime? expiry;
                          if (warrantyMonths != null) {
                            expiry = DateTime(
                              purchaseDate.year,
                              purchaseDate.month + warrantyMonths!,
                              purchaseDate.day,
                            );
                          }

                          await ReceiptManager.instance.addReceipt(
                            title: title,
                            storeName: store.isEmpty ? "Store" : store,
                            price: price,
                            purchaseDate: purchaseDate,
                            warrantyExpiryDate: expiry,
                            notes: notesController.text.trim(),
                          );

                          openSnackbar(
                            SnackbarMessage(
                              title: "Receipt Saved",
                              description: "$title saved to Warranty Vault.",
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

  @override
  Widget build(BuildContext context) {
    final receipts = ReceiptManager.instance.receipts;
    final expiringSoon = ReceiptManager.instance.getExpiringWarranties();
    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[appStateSettings["selectedWalletPk"]]?.currency ??
        "";

    return PageFramework(
      title: "Receipt & Warranty Vault",
      actions: [
        IconButton(
          tooltip: "Add Receipt",
          icon: const Icon(Icons.add_rounded),
          onPressed: _showAddReceiptModal,
        ),
      ],
      listWidgets: [
        // Expiring Soon Alert
        if (expiringSoon.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.amber.withOpacity(0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time_filled_rounded,
                      color: Colors.amber, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "${expiringSoon.length} Warranties Expiring Soon!",
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          textColor: Colors.amber[900],
                        ),
                        const SizedBox(height: 2),
                        TextFont(
                          text:
                              "${expiringSoon.first.title} expires in ${expiringSoon.first.warrantyDaysRemaining} days.",
                          fontSize: 12,
                          textColor: Colors.amber[800],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (receipts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60.0, horizontal: 24),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 64,
                    color: getColor(context, "textLight").withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  const TextFont(
                    text: "No Receipts Saved",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  const SizedBox(height: 8),
                  TextFont(
                    text:
                        "Safeguard your receipts and track product warranties with automated expiration alerts.",
                    textAlign: TextAlign.center,
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                  const SizedBox(height: 20),
                  Button(
                    label: "+ Add Receipt / Warranty",
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    onTap: _showAddReceiptModal,
                  ),
                ],
              ),
            ),
          )
        else
          ...receipts.map((r) {
            final isExpired = r.isWarrantyExpired;
            final days = r.warrantyDaysRemaining;

            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 5.0),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: getColor(context, "canvasContainer"),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: getColor(context, "dividerColor").withOpacity(0.3),
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
                            .withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.receipt_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFont(
                            text: r.title,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          const SizedBox(height: 2),
                          TextFont(
                            text:
                                "${r.storeName}  •  ${DateFormat('dd MMM yyyy').format(r.purchaseDate)}",
                            fontSize: 12,
                            textColor: getColor(context, "textLight"),
                          ),
                          if (r.hasWarranty) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isExpired
                                    ? Colors.grey.withOpacity(0.15)
                                    : (days <= 30
                                        ? Colors.amber.withOpacity(0.15)
                                        : Colors.green.withOpacity(0.12)),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: TextFont(
                                text: isExpired
                                    ? "Warranty Expired"
                                    : (days <= 30
                                        ? "Expires in $days days!"
                                        : "Warranty Active ($days days left)"),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                textColor: isExpired
                                    ? Colors.grey[700]
                                    : (days <= 30
                                        ? Colors.amber[900]
                                        : Colors.green[800]),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        TextFont(
                          text: "$currency${r.price.toStringAsFixed(2)}",
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded,
                              size: 18),
                          color: getColor(context, "textLight"),
                          onPressed: () async {
                            await ReceiptManager.instance.deleteReceipt(r.id);
                          },
                        ),
                      ],
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
