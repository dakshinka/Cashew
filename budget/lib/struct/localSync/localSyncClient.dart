import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/localSync/localSyncEngine.dart';

String safeJsonEncode(dynamic object) {
  return jsonEncode(object, toEncodable: (nonEncodable) {
    if (nonEncodable is Enum) {
      return nonEncodable.name;
    }
    if (nonEncodable is DateTime) {
      return nonEncodable.toIso8601String();
    }
    return nonEncodable.toString();
  });
}

class LocalSyncClientResult {
  final bool success;
  final String? errorMessage;
  final int itemsSent;
  final int itemsReceived;

  LocalSyncClientResult({
    required this.success,
    this.errorMessage,
    this.itemsSent = 0,
    this.itemsReceived = 0,
  });
}

class LocalSyncClient {
  static Future<Map<String, dynamic>?> checkServerStatus(
      String host, int port, {required String token}) async {
    final (sanitizedHost, effectivePort) =
        parseHostAndPort(host, defaultPort: port);
    final url = Uri.parse('http://$sanitizedHost:$effectivePort/api/status');
    try {
      final response = await http.get(url, headers: {
        "X-Sync-Token": token,
      }).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint("LocalSyncClient: checkServerStatus error: $e");
    }
    return null;
  }

  static Future<LocalSyncClientResult> syncWithServer({
    required String host,
    int port = 8765,
    required String token,
  }) async {
    final (sanitizedHost, effectivePort) =
        parseHostAndPort(host, defaultPort: port);
    final url = Uri.parse('http://$sanitizedHost:$effectivePort/api/sync');

    try {
      // 1. Get last synced timestamp for this host
      final String prefKey =
          "localSync_lastSynced_${sanitizedHost}_$effectivePort";
      final String? lastSyncedStr = sharedPreferences.getString(prefKey);
      final DateTime? lastSyncedUtc =
          lastSyncedStr != null ? DateTime.tryParse(lastSyncedStr)?.toUtc() : null;

      // 2. Export local changes
      final localChanges =
          await LocalSyncEngine.exportChanges(database, lastSyncedUtc);

      final payload = {
        "clientId": clientID,
        "lastSyncedUtc": lastSyncedUtc?.toIso8601String(),
        "changes": localChanges.toJson(),
      };

      // 3. Send securely to Server with authentication token
      final response = await http
          .post(
            url,
            headers: {
              "Content-Type": "application/json",
              "X-Client-ID": clientID,
              "X-Sync-Token": token,
            },
            body: safeJsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 401) {
        return LocalSyncClientResult(
          success: false,
          errorMessage:
              "Authentication Failed: Invalid security token. Please check the PIN or re-scan the QR code.",
        );
      }

      if (response.statusCode != 200) {
        return LocalSyncClientResult(
          success: false,
          errorMessage:
              "Server returned error code ${response.statusCode}: ${response.body}",
        );
      }

      final responseJson = jsonDecode(response.body) as Map<String, dynamic>;
      if (responseJson['success'] != true) {
        return LocalSyncClientResult(
          success: false,
          errorMessage: responseJson['error'] ?? "Unknown sync error",
        );
      }

      // 4. Ingest server changes
      final serverChangesJson =
          responseJson['serverChanges'] as Map<String, dynamic>?;
      int receivedCount = 0;
      if (serverChangesJson != null) {
        final serverChanges = LocalSyncChangeset.fromJson(serverChangesJson);
        receivedCount = serverChanges.totalCount;
        await LocalSyncEngine.importChanges(database, serverChanges);
      }

      // 5. Store updated sync timestamp
      final String serverTimestamp = responseJson['syncTimestampUtc'] ??
          DateTime.now().toUtc().toIso8601String();
      await sharedPreferences.setString(prefKey, serverTimestamp);

      return LocalSyncClientResult(
        success: true,
        itemsSent: localChanges.totalCount,
        itemsReceived: receivedCount,
      );
    } catch (e) {
      debugPrint("LocalSyncClient: syncWithServer error: $e");
      return LocalSyncClientResult(
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  static (String, int) parseHostAndPort(String input,
      {int defaultPort = 8765}) {
    var host = input.trim();
    if (host.startsWith('http://')) host = host.substring(7);
    if (host.startsWith('https://')) host = host.substring(8);
    if (host.contains('?')) host = host.split('?')[0];
    if (host.contains('/')) host = host.split('/')[0];
    int port = defaultPort;
    if (host.contains(':')) {
      final parts = host.split(':');
      host = parts[0];
      port = int.tryParse(parts[1]) ?? defaultPort;
    }
    return (host, port);
  }

  static String? extractTokenFromInput(String input) {
    if (input.contains('token=')) {
      final uri = Uri.tryParse(input.trim());
      if (uri != null && uri.queryParameters.containsKey('token')) {
        return uri.queryParameters['token'];
      }
      final parts = input.split('token=');
      if (parts.length > 1) {
        return parts[1].split('&')[0].trim();
      }
    }
    return null;
  }
}
