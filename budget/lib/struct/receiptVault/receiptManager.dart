import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:budget/main.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/receiptVault/receiptModels.dart';

const String _kReceiptVaultStorageKey = "cashew_receipt_vault_v1";

class ReceiptManager extends ChangeNotifier {
  static final ReceiptManager instance = ReceiptManager._internal();
  ReceiptManager._internal();

  final List<ReceiptItem> _receipts = [];
  bool _initialized = false;

  List<ReceiptItem> get receipts => List.unmodifiable(_receipts);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    try {
      final raw = sharedPreferences.getString(_kReceiptVaultStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> list = jsonDecode(raw);
        _receipts.clear();
        for (final item in list) {
          _receipts.add(ReceiptItem.fromJson(item as Map<String, dynamic>));
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error loading receipts: $e");
    }
  }

  Future<void> _saveToDisk() async {
    try {
      final list = _receipts.map((r) => r.toJson()).toList();
      await sharedPreferences.setString(
          _kReceiptVaultStorageKey, jsonEncode(list));
      notifyListeners();
    } catch (e) {
      debugPrint("Error saving receipts: $e");
    }
  }

  List<ReceiptItem> getExpiringWarranties({int withinDays = 30}) {
    final now = DateTime.now();
    final threshold = now.add(Duration(days: withinDays));
    return _receipts
        .where((r) =>
            r.hasWarranty &&
            r.warrantyExpiryDate!.isAfter(now) &&
            r.warrantyExpiryDate!.isBefore(threshold))
        .toList();
  }

  Future<ReceiptItem> addReceipt({
    required String title,
    required String storeName,
    required double price,
    required DateTime purchaseDate,
    DateTime? warrantyExpiryDate,
    String? notes,
    String? imagePath,
    String? transactionPk,
  }) async {
    final item = ReceiptItem(
      title: title.trim(),
      storeName: storeName.trim(),
      price: price,
      purchaseDate: purchaseDate,
      warrantyExpiryDate: warrantyExpiryDate,
      notes: notes,
      imagePath: imagePath,
      transactionPk: transactionPk,
    );

    _receipts.insert(0, item);
    await _saveToDisk();
    return item;
  }

  Future<void> deleteReceipt(String id) async {
    _receipts.removeWhere((r) => r.id == id);
    await _saveToDisk();
  }
}
