import 'package:flutter/services.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/smsParser.dart';

class SmsInboxScanner {
  static const MethodChannel _channel =
      MethodChannel('com.budget.tracker_app/sms_inbox');

  /// Check whether the Android READ_SMS permission is granted
  static Future<bool> hasPermission() async {
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('checkSmsPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Request runtime READ_SMS permission from Android
  static Future<bool> requestPermission() async {
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('requestSmsPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Queries the Android SMS inbox for financial messages
  static Future<List<Map<String, dynamic>>> queryInbox({
    DateTime? fromDate,
    DateTime? toDate,
    int days = 60,
    int limit = 500,
  }) async {
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) return [];
    try {
      final Map<String, dynamic> args = {
        'days': days,
        'limit': limit,
      };
      if (fromDate != null) {
        args['startTimeMillis'] = fromDate.millisecondsSinceEpoch;
      }
      if (toDate != null) {
        final endOfDay =
            DateTime(toDate.year, toDate.month, toDate.day, 23, 59, 59, 999);
        args['endTimeMillis'] = endOfDay.millisecondsSinceEpoch;
      }
      final List<dynamic>? raw = await _channel.invokeMethod('querySmsInbox', args);
      if (raw == null) return [];
      return raw.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Scans historical SMS inbox messages and imports them into ReviewManager
  static Future<int> scanAndImport({
    DateTime? fromDate,
    DateTime? toDate,
    int days = 60,
    int limit = 500,
    Function(int current, int total)? onProgress,
  }) async {
    bool granted = await hasPermission();
    if (!granted) {
      granted = await requestPermission();
      if (!granted) return 0;
    }

    final messages = await queryInbox(
      fromDate: fromDate,
      toDate: toDate,
      days: days,
      limit: limit,
    );
    if (messages.isEmpty) return 0;

    int importedCount = 0;
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final body = msg['body']?.toString() ?? '';
      final dateMillis = msg['date'] as int?;
      if (body.trim().isEmpty) continue;

      final parsed = SmsParser.parse(body);
      if (!parsed.success) continue;

      DateTime effectiveDate = parsed.date;
      // If the parsed date was same as today (default), use the SMS message timestamp
      if (dateMillis != null && dateMillis > 0) {
        final smsDate = DateTime.fromMillisecondsSinceEpoch(dateMillis);
        final now = DateTime.now();
        if (parsed.date.year == now.year &&
            parsed.date.month == now.month &&
            parsed.date.day == now.day) {
          effectiveDate = smsDate;
        }
      }

      final item = await ReviewManager.instance.processRawMessage(
        body,
        overrideDate: effectiveDate,
      );

      if (item != null) {
        importedCount++;
      }

      if (onProgress != null) {
        onProgress(i + 1, messages.length);
      }
    }

    return importedCount;
  }
}
