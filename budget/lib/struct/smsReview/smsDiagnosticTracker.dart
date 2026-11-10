import 'package:flutter/foundation.dart';

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
}

class SmsDiagnosticTracker {
  static final SmsDiagnosticTracker instance = SmsDiagnosticTracker._();
  SmsDiagnosticTracker._();

  final ValueNotifier<List<SmsDiagnosticEntry>> logsNotifier =
      ValueNotifier<List<SmsDiagnosticEntry>>([]);

  List<SmsDiagnosticEntry> get logs => logsNotifier.value;

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
    current.insert(0, entry);
    if (current.length > 250) {
      current.removeRange(250, current.length);
    }
    logsNotifier.value = current;
  }

  void clear() {
    logsNotifier.value = [];
  }
}
