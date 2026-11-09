import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/vendorTabs/vendorTabModels.dart';

class VendorTabManager extends ChangeNotifier {
  static final VendorTabManager instance = VendorTabManager._();
  VendorTabManager._();

  static const String _storageKey = "vendor_tabs_daily_services";
  final List<DailyDeliveryService> _services = [];

  List<DailyDeliveryService> get services => List.unmodifiable(_services);
  List<DailyDeliveryService> get dailyServices => services;

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final jsonStr = sharedPreferences.getString(_storageKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final list = jsonDecode(jsonStr) as List;
        _services.clear();
        for (final item in list) {
          _services.add(
              DailyDeliveryService.fromJson(Map<String, dynamic>.from(item)));
        }
      } catch (e) {
        debugPrint("Error loading vendor tab services: $e");
      }
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final list = _services.map((s) => s.toJson()).toList();
    await sharedPreferences.setString(_storageKey, jsonEncode(list));
    notifyListeners();
  }

  DailyDeliveryService? getService(String servicePk) {
    try {
      return _services.firstWhere((s) => s.servicePk == servicePk);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveService(DailyDeliveryService service) async {
    final index = _services.indexWhere((s) => s.servicePk == service.servicePk);
    service.dateTimeModified = DateTime.now();
    if (index >= 0) {
      _services[index] = service;
    } else {
      _services.add(service);
    }
    await _persist();
  }

  Future<void> deleteService(String servicePk) async {
    _services.removeWhere((s) => s.servicePk == servicePk);
    await _persist();
  }

  /// Posts the calculated monthly expense to the Vendor Tab wallet in the database
  Future<Transaction?> postMonthlyStatementToTab({
    required DailyDeliveryService service,
    required int year,
    required int month,
  }) async {
    final summary = service.calculateMonth(year, month);
    if (summary.totalCost <= 0) return null;

    final categories = await database.getAllCategories();
    final String categoryPk = service.categoryPk ??
        (categories.isNotEmpty ? categories.first.categoryPk : "0");

    final monthName = _getMonthName(month);
    final note =
        "${summary.deliveredDays} delivery days (${summary.totalUnits.toStringAsFixed(1)} ${service.unitName}), "
        "${summary.skippedDaysCount} skipped, ${summary.extraDaysCount} extra days.";

    final transaction = Transaction(
      transactionPk: uuid.v4(),
      name: "${service.name} ($monthName $year)",
      amount: summary.totalCost,
      note: note,
      categoryFk: categoryPk,
      walletFk: service.vendorTabWalletPk,
      income: false,
      dateCreated: DateTime(year, month, summary.totalDaysInMonth, 23, 59),
      paid: true,
      skipPaid: false,
      dateTimeModified: DateTime.now(),
    );

    await database.createOrUpdateTransaction(transaction, insert: true);
    return transaction;
  }

  static String _getMonthName(int month) {
    const months = [
      "January",
      "February",
      "March",
      "April",
      "May",
      "June",
      "July",
      "August",
      "September",
      "October",
      "November",
      "December"
    ];
    return months[month - 1];
  }
}
extension MonthlySummaryExtensions on MonthlyDeliverySummary {
  int get deliveredDays => normalDaysCount + extraDaysCount;
}
