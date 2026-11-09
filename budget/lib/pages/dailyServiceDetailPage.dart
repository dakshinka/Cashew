import 'package:flutter/material.dart';
import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/vendorTabs/vendorTabManager.dart';
import 'package:budget/struct/vendorTabs/vendorTabModels.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class DailyServiceDetailPage extends StatefulWidget {
  final String servicePk;

  const DailyServiceDetailPage({Key? key, required this.servicePk})
      : super(key: key);

  @override
  State<DailyServiceDetailPage> createState() => _DailyServiceDetailPageState();
}

class _DailyServiceDetailPageState extends State<DailyServiceDetailPage> {
  late DateTime _selectedMonth;
  DailyDeliveryService? _service;

  @override
  void initState() {
    super.initState();
    _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
    _loadService();
  }

  void _loadService() {
    _service = VendorTabManager.instance.getService(widget.servicePk);
    setState(() {});
  }

  String getCurrencyString(double amount) {
    return "\$${amount.toStringAsFixed(2)}";
  }

  void _previousMonth() {
    setState(() {
      _selectedMonth =
          DateTime(_selectedMonth.year, _selectedMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _selectedMonth =
          DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
    });
  }

  void _showAddRateChangeDialog() {
    final priceController = TextEditingController();
    DateTime effectiveDate = DateTime.now();

    openPopup(
      context,
      title: "Add Price Rate Change",
      description:
          "Specify the new price and the date it becomes effective (e.g. ₹37 from Nov 18):",
      onSubmitLabel: "Save Rate",
      onSubmit: () async {
        final price = double.tryParse(priceController.text.trim());
        if (price == null || price <= 0 || _service == null) return;

        // Close previous period
        if (_service!.ratePeriods.isNotEmpty) {
          final last = _service!.ratePeriods.last;
          if (last.endDate == null || last.endDate!.isAfter(effectiveDate)) {
            final updatedLast = RateSchedulePeriod(
              periodId: last.periodId,
              startDate: last.startDate,
              endDate: effectiveDate.subtract(const Duration(days: 1)),
              unitPrice: last.unitPrice,
              unitName: last.unitName,
            );
            _service!.ratePeriods[_service!.ratePeriods.length - 1] =
                updatedLast;
          }
        }

        // Add new ongoing period
        _service!.ratePeriods.add(RateSchedulePeriod(
          startDate: effectiveDate,
          endDate: null,
          unitPrice: price,
          unitName: _service!.unitName,
        ));

        await VendorTabManager.instance.saveService(_service!);
        _loadService();
        popRoute(context);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context),
      beforeDescriptionWidget: StatefulBuilder(
        builder: (context, setDialogState) {
          return Column(
            children: [
              TextInput(
                labelText: "New Unit Price (${_service?.unitName ?? 'unit'})",
                controller: priceController,
                numbersOnly: true,
                padding: const EdgeInsetsDirectional.only(bottom: 12),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextFont(
                    text:
                        "Effective From: ${effectiveDate.day}/${effectiveDate.month}/${effectiveDate.year}",
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: effectiveDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2035),
                      );
                      if (picked != null) {
                        setDialogState(() {
                          effectiveDate = picked;
                        });
                      }
                    },
                    child: const Text("Change Date"),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDayAdjustPopup(DateTime date) {
    if (_service == null) return;
    final currentQty = _service!.getQuantityForDate(date);
    final unitPrice = _service!.getPriceForDate(date);

    openBottomSheet(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFont(
              text: "Delivery on ${date.day}/${date.month}/${date.year}",
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            const SizedBox(height: 6),
            TextFont(
              text:
                  "Rate on this day: ${getCurrencyString(unitPrice)} / ${_service!.unitName}",
              fontSize: 14,
              textColor: getColor(context, "textLight"),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.check_circle_outline, color: Colors.green),
              title: TextFont(
                text: "Standard Delivery (${_service!.defaultDailyQuantity} ${_service!.unitName})",
                fontSize: 15,
              ),
              subtitle: TextFont(
                text: "Cost: ${getCurrencyString(_service!.defaultDailyQuantity * unitPrice)}",
                fontSize: 12,
                textColor: getColor(context, "textLight"),
              ),
              onTap: () async {
                _service!.setOverrideForDate(date, null);
                await VendorTabManager.instance.saveService(_service!);
                _loadService();
                popRoute(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cancel_outlined, color: Colors.red),
              title: const TextFont(
                text: "Skip Delivery (0 units)",
                fontSize: 15,
              ),
              subtitle: TextFont(
                text: "No delivery / vacation day (Cost: ${getCurrencyString(0)})",
                fontSize: 12,
                textColor: getColor(context, "textLight"),
              ),
              onTap: () async {
                _service!.setOverrideForDate(date, 0.0);
                await VendorTabManager.instance.saveService(_service!);
                _loadService();
                popRoute(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: Colors.blue),
              title: TextFont(
                text: "Extra Delivery (${_service!.defaultDailyQuantity + 1.0} ${_service!.unitName})",
                fontSize: 15,
              ),
              subtitle: TextFont(
                text: "Cost: ${getCurrencyString((_service!.defaultDailyQuantity + 1.0) * unitPrice)}",
                fontSize: 12,
                textColor: getColor(context, "textLight"),
              ),
              onTap: () async {
                _service!.setOverrideForDate(
                    date, _service!.defaultDailyQuantity + 1.0);
                await VendorTabManager.instance.saveService(_service!);
                _loadService();
                popRoute(context);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _postMonthToTab() async {
    if (_service == null) return;
    final summary = _service!.calculateMonth(
        _selectedMonth.year, _selectedMonth.month);

    final result = await openPopup(
      context,
      title: "Post to Vendor Tab",
      description:
          "Post monthly total of ${getCurrencyString(summary.totalCost)} for "
          "${_getMonthName(_selectedMonth.month)} ${_selectedMonth.year} to this vendor tab?",
      onSubmitLabel: "Post Expense",
      onSubmit: () async {
        popRoute(context, true);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context, false),
    );

    if (result == true) {
      await VendorTabManager.instance.postMonthlyStatementToTab(
        service: _service!,
        year: _selectedMonth.year,
        month: _selectedMonth.month,
      );
      openSnackbar(
        SnackbarMessage(
          title: "Posted to Vendor Tab!",
          icon: Icons.check_circle_outline,
        ),
      );
    }
  }

  Future<void> _settleTab() async {
    if (_service == null) return;
    final wallet = await database.getWalletInstance(_service!.vendorTabWalletPk);
    final summary = _service!.calculateMonth(
        _selectedMonth.year, _selectedMonth.month);

    openBottomSheet(
      context,
      TransferBalancePopup(
        wallet: wallet,
        allowEditWallet: true,
        initialAmount: summary.totalCost,
        initialTitle: "Settle ${_service!.name} (${_getMonthName(_selectedMonth.month)})",
      ),
    );
  }

  String _getMonthName(int month) {
    const m = [
      "January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December"
    ];
    return m[month - 1];
  }

  @override
  Widget build(BuildContext context) {
    if (_service == null) {
      return PageFramework(
        title: "Daily Service",
        dragDownToDismiss: true,
        listWidgets: const [
          Center(child: Text("Service not found")),
        ],
      );
    }

    final theme = Theme.of(context);
    final summary = _service!.calculateMonth(
        _selectedMonth.year, _selectedMonth.month);

    return PageFramework(
      title: _service!.name,
      dragDownToDismiss: true,
      listWidgets: [
        // Rate Schedule Section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextFont(
                      text: "Rate Schedules",
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text("Rate Change"),
                      onPressed: _showAddRateChangeDialog,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final r in _service!.ratePeriods)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextFont(
                          text: r.endDate == null
                              ? "From ${r.startDate.day}/${r.startDate.month}/${r.startDate.year} (Active)"
                              : "${r.startDate.day}/${r.startDate.month} – ${r.endDate!.day}/${r.endDate!.month}/${r.endDate!.year}",
                          fontSize: 13,
                        ),
                        TextFont(
                          text:
                              "${getCurrencyString(r.unitPrice)} / ${r.unitName}",
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          textColor: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Month Selector Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, size: 28),
                onPressed: _previousMonth,
              ),
              TextFont(
                text:
                    "${_getMonthName(_selectedMonth.month)} ${_selectedMonth.year}",
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded, size: 28),
                onPressed: _nextMonth,
              ),
            ],
          ),
        ),

        // Delivery Calendar Grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
            ),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 0.9,
              ),
              itemCount: summary.dailyDetails.length,
              itemBuilder: (context, index) {
                final day = summary.dailyDetails[index];
                Color bgColor = theme.colorScheme.surfaceVariant.withOpacity(0.3);
                Color textColor = theme.colorScheme.onSurface;

                if (day.isSkipped) {
                  bgColor = Colors.red.withOpacity(0.15);
                  textColor = Colors.red.shade700;
                } else if (day.isExtra) {
                  bgColor = Colors.blue.withOpacity(0.2);
                  textColor = Colors.blue.shade800;
                }

                return InkWell(
                  onTap: () => _showDayAdjustPopup(day.date),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: day.isSkipped
                            ? Colors.red.withOpacity(0.4)
                            : (day.isExtra
                                ? Colors.blue.withOpacity(0.4)
                                : Colors.transparent),
                      ),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextFont(
                          text: "${day.date.day}",
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          textColor: textColor,
                        ),
                        const SizedBox(height: 2),
                        TextFont(
                          text: day.isSkipped
                              ? "Skip"
                              : "${day.quantity.toStringAsFixed(day.quantity.truncateToDouble() == day.quantity ? 0 : 1)}${_service!.unitName}",
                          fontSize: 10,
                          textColor: textColor,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // Monthly Statement Summary Box
        Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withOpacity(0.25),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextFont(
                      text: "Month Total Due",
                      fontSize: 15,
                      textColor: getColor(context, "textLight"),
                    ),
                    TextFont(
                      text: getCurrencyString(summary.totalCost),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      textColor: theme.colorScheme.primary,
                    ),
                  ],
                ),
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextFont(
                      text:
                          "Delivered: ${summary.deliveredDays} days (${summary.totalUnits.toStringAsFixed(1)} ${_service!.unitName})",
                      fontSize: 13,
                    ),
                    TextFont(
                      text: "Skipped: ${summary.skippedDaysCount} days",
                      fontSize: 13,
                      textColor: Colors.red.shade600,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Action Buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Button(
                  label: "Post Month to Tab",
                  icon: Icons.receipt_long_rounded,
                  onTap: _postMonthToTab,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Button(
                  label: "Settle & Pay",
                  icon: Icons.payments_rounded,
                  color: theme.colorScheme.primary,
                  textColor: theme.colorScheme.onPrimary,
                  onTap: _settleTab,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}
