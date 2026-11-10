import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/reviewModels.dart';

const String _kSmsDiagnosticStorageKey = "cached_sms_diagnostic_logs_v1";

class SmsDiagnosticEntry {
  final String id;
  final String sender;
  final String rawMessage;
  final DateTime timestamp;
  final String status; // "captured", "other_sms", "skipped", "duplicate"
  final String reason;
  final double? detectedAmount;
  final String? detectedMerchant;
  final String? detectedAccount;
  final bool isIncome;

  SmsDiagnosticEntry({
    required this.id,
    this.sender = "SMS",
    required this.rawMessage,
    required this.timestamp,
    required this.status,
    required this.reason,
    this.detectedAmount,
    this.detectedMerchant,
    this.detectedAccount,
    this.isIncome = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender': sender,
        'rawMessage': rawMessage,
        'timestamp': timestamp.toIso8601String(),
        'status': status,
        'reason': reason,
        'detectedAmount': detectedAmount,
        'detectedMerchant': detectedMerchant,
        'detectedAccount': detectedAccount,
        'isIncome': isIncome,
      };

  factory SmsDiagnosticEntry.fromJson(Map<String, dynamic> json) =>
      SmsDiagnosticEntry(
        id: json['id'] as String? ?? '',
        sender: json['sender'] as String? ?? 'SMS',
        rawMessage: json['rawMessage'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'] as String)
            : DateTime.now(),
        status: json['status'] as String? ?? 'skipped',
        reason: json['reason'] as String? ?? '',
        detectedAmount: (json['detectedAmount'] as num?)?.toDouble(),
        detectedMerchant: json['detectedMerchant'] as String?,
        detectedAccount: json['detectedAccount'] as String?,
        isIncome: json['isIncome'] as bool? ?? false,
      );
}

class SmsDiagnosticTracker {
  static final SmsDiagnosticTracker instance = SmsDiagnosticTracker._();
  SmsDiagnosticTracker._();

  final ValueNotifier<List<SmsDiagnosticEntry>> logsNotifier =
      ValueNotifier<List<SmsDiagnosticEntry>>([]);

  List<SmsDiagnosticEntry> get logs => logsNotifier.value;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      await syncHistoricalData();
      return;
    }
    _initialized = true;
    await loadFromStorage();
    await syncHistoricalData();
  }

  Future<void> loadFromStorage() async {
    try {
      final raw = appStateSettings[_kSmsDiagnosticStorageKey];
      if (raw != null && raw is String && raw.isNotEmpty) {
        final List<dynamic> list = jsonDecode(raw);
        final loaded = list
            .map((item) =>
                SmsDiagnosticEntry.fromJson(item as Map<String, dynamic>))
            .toList();
        logsNotifier.value = loaded;
      }
    } catch (e) {
      debugPrint("Error loading sms diagnostic logs: $e");
    }
  }

  Future<void> saveToStorage() async {
    try {
      final jsonList = logsNotifier.value.map((i) => i.toJson()).toList();
      await updateSettings(_kSmsDiagnosticStorageKey, jsonEncode(jsonList),
          updateGlobalState: false);
    } catch (e) {
      debugPrint("Error saving sms diagnostic logs: $e");
    }
  }

  /// Syncs all existing items from Review Inbox (pending & other SMS)
  /// as well as past auto-logged transactions from Cashew database!
  Future<void> syncHistoricalData() async {
    final Map<String, SmsDiagnosticEntry> byMessage = {};

    // 1. Keep existing logs
    for (final entry in logsNotifier.value) {
      final key = entry.rawMessage.trim();
      if (key.isNotEmpty && !byMessage.containsKey(key)) {
        byMessage[key] = entry;
      }
    }

    // 2. Load from Review Inbox items (pending + ignored)
    final inboxItems = ReviewManager.instance.allTransactions;
    for (final item in inboxItems) {
      final key = item.rawMessage.trim();
      if (key.isEmpty) continue;

      final isPending = item.status == ReviewStatus.pending;
      final isIgnored = item.status == ReviewStatus.ignored;

      final entry = SmsDiagnosticEntry(
        id: item.id,
        sender: "Review Inbox",
        rawMessage: item.rawMessage,
        timestamp: item.date,
        status: isPending
            ? "captured"
            : (isIgnored ? "other_sms" : "duplicate"),
        reason: isPending
            ? "In Review Inbox: ${item.cleanMerchant} (${item.displayCurrency}${item.amount.toStringAsFixed(2)})"
            : (isIgnored
                ? (item.ignoredReason ?? "In Other SMS: Non-transaction alert")
                : "Approved transaction in accounts"),
        detectedAmount: item.amount,
        detectedMerchant: item.cleanMerchant,
        detectedAccount: item.accountHint,
        isIncome: item.isIncome,
      );

      // Overwrite or add inbox item
      byMessage[key] = entry;
    }

    // 3. Load from Cashew database transactions auto-logged from SMS
    try {
      final allTxns = await database.allTransactions;
      for (final t in allTxns) {
        final note = t.note;
        const prefix = "Auto-logged from SMS/Notification:\n";
        if (note.contains(prefix)) {
          final raw =
              note.substring(note.indexOf(prefix) + prefix.length).trim();
          if (raw.isNotEmpty && !byMessage.containsKey(raw)) {
            byMessage[raw] = SmsDiagnosticEntry(
              id: t.transactionPk,
              sender: "Database",
              rawMessage: raw,
              timestamp: t.dateCreated,
              status: "duplicate",
              reason:
                  "Approved & Logged in Accounts: ${t.name} (₹${t.amount.abs().toStringAsFixed(2)})",
              detectedAmount: t.amount.abs(),
              detectedMerchant: t.name,
              isIncome: t.income,
            );
          }
        }
      }
    } catch (_) {}

    final list = byMessage.values.toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (list.length > 300) {
      list.removeRange(300, list.length);
    }
    logsNotifier.value = list;
    await saveToStorage();
  }

  void log({
    String sender = "SMS",
    required String rawMessage,
    required DateTime timestamp,
    required String status,
    required String reason,
    double? detectedAmount,
    String? detectedMerchant,
    String? detectedAccount,
    bool isIncome = false,
  }) {
    final entry = SmsDiagnosticEntry(
      id: "${DateTime.now().millisecondsSinceEpoch}_${logs.length}",
      sender: sender,
      rawMessage: rawMessage,
      timestamp: timestamp,
      status: status,
      reason: reason,
      detectedAmount: detectedAmount,
      detectedMerchant: detectedMerchant,
      detectedAccount: detectedAccount,
      isIncome: isIncome,
    );

    final current = List<SmsDiagnosticEntry>.from(logsNotifier.value);
    current.removeWhere((e) => e.rawMessage.trim() == rawMessage.trim());
    current.insert(0, entry);
    if (current.length > 300) {
      current.removeRange(300, current.length);
    }
    logsNotifier.value = current;
    saveToStorage();
  }

  Future<void> clear() async {
    logsNotifier.value = [];
    await saveToStorage();
  }
}
