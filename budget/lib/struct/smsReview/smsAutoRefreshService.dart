import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/smsInboxScanner.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';

class SmsAutoRefreshService {
  static final SmsAutoRefreshService instance =
      SmsAutoRefreshService._internal();
  SmsAutoRefreshService._internal();

  static const MethodChannel _smsChannel =
      MethodChannel('com.budget.tracker_app/sms_inbox');

  Timer? _periodicTimer;
  bool _isInitialized = false;
  final ValueNotifier<bool> isScanning = ValueNotifier<bool>(false);
  final ValueNotifier<DateTime?> lastScanTime = ValueNotifier<DateTime?>(null);

  /// Initializes real-time SMS listeners and periodic auto-refresh timer
  Future<void> init() async {
    if (_isInitialized) return;
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) return;
    _isInitialized = true;

    // Set up native method channel handler for real-time events
    _smsChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case "onSmsInboxChanged":
          debugPrint("SmsAutoRefreshService: Native onSmsInboxChanged triggered");
          await scanIncremental(silent: true);
          break;
        case "onRawSmsReceived":
          debugPrint("SmsAutoRefreshService: Native onRawSmsReceived triggered");
          final data = call.arguments as Map?;
          if (data != null) {
            final body = data['body']?.toString() ?? '';
            final sender = data['address']?.toString() ?? 'SMS';
            final dateMillis = data['date'] as int?;
            DateTime? date;
            if (dateMillis != null && dateMillis > 0) {
              date = DateTime.fromMillisecondsSinceEpoch(dateMillis);
            }
            if (body.trim().isNotEmpty) {
              final item = await ReviewManager.instance.processRawMessage(
                body,
                sender: sender,
                overrideDate: date,
              );
              if (item != null) {
                openSnackbar(
                  SnackbarMessage(
                    title: "SMS Captured in Real-Time",
                    description:
                        "${item.cleanMerchant}: ${item.displayCurrency}${item.amount.toStringAsFixed(2)}",
                    icon: Icons.mark_email_unread_outlined,
                  ),
                );
              }
            }
          }
          break;
      }
    });

    // Ask native side to start listening for SMS if permission is already granted
    try {
      final hasPerm = await SmsInboxScanner.hasPermission();
      if (hasPerm) {
        await _smsChannel.invokeMethod('startListeningForSms');
      }
    } catch (_) {}

    // Initialize the last scan timestamp if not present
    final lastMs = appStateSettings["lastSmsScanTimestamp"] as int? ?? 0;
    if (lastMs > 0) {
      lastScanTime.value = DateTime.fromMillisecondsSinceEpoch(lastMs);
    }

    // Start timer according to user preferences
    restartTimer();

    // Trigger initial scan on startup if enabled
    if (appStateSettings["autoSmsScanEnabled"] == true) {
      Future.delayed(const Duration(seconds: 3), () {
        scanIncremental(silent: true);
      });
    }
  }

  /// Restarts the periodic timer based on user settings
  void restartTimer() {
    _periodicTimer?.cancel();
    _periodicTimer = null;

    final enabled = appStateSettings["autoSmsScanEnabled"] == true;
    if (!enabled) return;

    final intervalMinutes =
        appStateSettings["autoSmsScanIntervalMinutes"] as int? ?? 15;
    if (intervalMinutes <= 0) {
      // 0 or -1 means only on app open / resume or real-time, no timer polling
      return;
    }

    _periodicTimer = Timer.periodic(
      Duration(minutes: intervalMinutes),
      (_) async {
        debugPrint(
            "SmsAutoRefreshService: Timer fired ($intervalMinutes min interval)");
        await scanIncremental(silent: true);
      },
    );
  }

  /// Called when app resumes from background (switch into app or unlock phone)
  Future<void> onAppResume() async {
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) return;
    if (appStateSettings["autoSmsScanEnabled"] != true) return;
    if (appStateSettings["autoSmsScanOnAppResume"] != true) return;

    debugPrint("SmsAutoRefreshService: App resumed, running incremental sync");
    await scanIncremental(silent: true);
  }

  /// Performs an incremental scan since the last scan timestamp
  Future<int> scanIncremental({bool silent = false}) async {
    if (isScanning.value) return 0;
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) return 0;

    final hasPerm = await SmsInboxScanner.hasPermission();
    if (!hasPerm) return 0;

    isScanning.value = true;
    int importedCount = 0;

    try {
      final now = DateTime.now();
      final lastMs = appStateSettings["lastSmsScanTimestamp"] as int? ?? 0;

      DateTime fromDate;
      if (lastMs > 0) {
        // Overlap by 1 minute to avoid boundary edge cases
        fromDate = DateTime.fromMillisecondsSinceEpoch(lastMs - 60000);
      } else {
        // Default to last 3 days for initial automatic scan
        fromDate = now.subtract(const Duration(days: 3));
      }

      importedCount = await SmsInboxScanner.scanAndImport(
        fromDate: fromDate,
        toDate: now,
        days: 3,
        limit: 100,
      );

      // Update timestamp to current scan time
      final nowMs = now.millisecondsSinceEpoch;
      await updateSettings("lastSmsScanTimestamp", nowMs,
          updateGlobalState: false);
      lastScanTime.value = now;

      if (importedCount > 0) {
        openSnackbar(
          SnackbarMessage(
            title: importedCount == 1
                ? "1 New Transaction Captured"
                : "$importedCount New Transactions Captured",
            description: "Automatically added to Review Inbox for verification.",
            icon: Icons.mark_email_unread_outlined,
          ),
        );
      } else if (!silent) {
        openSnackbar(
          SnackbarMessage(
            title: "SMS Inbox Up to Date",
            description: "No new banking transactions found.",
            icon: Icons.check_circle_outline,
          ),
        );
      }
    } catch (e) {
      debugPrint("SmsAutoRefreshService error: $e");
    } finally {
      isScanning.value = false;
    }

    return importedCount;
  }

  /// Manually triggers a scan from the UI
  Future<int> scanNow({bool showToast = true}) async {
    return await scanIncremental(silent: !showToast);
  }

  void stop() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }
}
