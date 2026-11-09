import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/localSync/localSyncEngine.dart';
import 'package:budget/struct/settings.dart';

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

class LocalSyncServerImplementation {
  static HttpServer? _server;
  static int currentPort = 8765;
  static bool get isRunning => _server != null;

  static const String _tokenPrefKey = "localSync_securityToken";

  /// Gets or generates an easy-to-type 6-digit security PIN
  static String getOrGenerateSecurityToken() {
    String? token = sharedPreferences.getString(_tokenPrefKey);
    if (token == null || token.isEmpty || token.length > 8) {
      final rand = Random.secure();
      token = (100000 + rand.nextInt(900000)).toString();
      sharedPreferences.setString(_tokenPrefKey, token);
    }
    return token;
  }

  static void setSecurityToken(String customPin) {
    sharedPreferences.setString(_tokenPrefKey, customPin.trim());
  }

  /// Regenerates the PIN (invalidates all previous pairings)
  static String regenerateSecurityToken() {
    final rand = Random.secure();
    final token = (100000 + rand.nextInt(900000)).toString();
    sharedPreferences.setString(_tokenPrefKey, token);
    return token;
  }

  static Future<List<String>> getLocalIpAddresses() async {
    final List<String> ips = [];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.address.isNotEmpty) {
            ips.add(addr.address);
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching local IPs: $e");
    }
    return ips;
  }

  static Future<bool> startServer({int port = 8765}) async {
    if (_server != null) return true;
    currentPort = port;
    getOrGenerateSecurityToken();
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint("LocalSyncServer running securely on port $port");
      _server!.listen(_handleRequest);
      return true;
    } catch (e) {
      debugPrint("Error starting LocalSyncServer: $e");
      _server = null;
      return false;
    }
  }

  static Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    // Add CORS headers for web clients
    request.response.headers.add("Access-Control-Allow-Origin", "*");
    request.response.headers.add(
        "Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    request.response.headers.add(
        "Access-Control-Allow-Headers", "Content-Type, X-Client-ID, X-Sync-Token");

    if (request.method == "OPTIONS") {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    // 1. Authentication Security Verification
    final expectedToken = getOrGenerateSecurityToken();
    final providedToken = request.headers.value("X-Sync-Token") ??
        request.uri.queryParameters["token"];

    if (providedToken == null || providedToken != expectedToken) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        "error": "Unauthorized: Invalid or missing sync security token.",
        "code": 401,
      }));
      await request.response.close();
      return;
    }

    // 2. Payload Size Protection (Anti-DoS / Anti-Memory exhaustion)
    if (request.contentLength > 25 * 1024 * 1024) {
      request.response.statusCode = HttpStatus.requestEntityTooLarge;
      request.response.write("Payload exceeds 25 MB security limit");
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    try {
      if (path == "/api/status" && request.method == "GET") {
        final status = {
          "status": "online",
          "authenticated": true,
          "deviceName": appStateSettings["username"] ?? "Cashew Desktop",
          "clientId": clientID,
          "serverTimeUtc": DateTime.now().toUtc().toIso8601String(),
          "version": 1,
        };
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(status));
      } else if (path == "/api/sync" && request.method == "POST") {
        final bodyStr = await utf8.decoder.bind(request).join();
        final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;

        final clientLastSyncedStr = bodyJson['lastSyncedUtc'] as String?;
        final clientLastSynced = clientLastSyncedStr != null
            ? DateTime.tryParse(clientLastSyncedStr)?.toUtc()
            : null;
        final clientChangesJson = bodyJson['changes'] as Map<String, dynamic>?;

        // 1. Ingest incoming client changes through type-checked Drift companions
        Map<String, int> importStats = {};
        if (clientChangesJson != null) {
          final incomingChangeset =
              LocalSyncChangeset.fromJson(clientChangesJson);
          importStats = await LocalSyncEngine.importChanges(
              database, incomingChangeset);
        }

        // 2. Export server changes that client might need
        final outgoingChangeset =
            await LocalSyncEngine.exportChanges(database, clientLastSynced);

        final responsePayload = {
          "success": true,
          "authenticated": true,
          "syncTimestampUtc": DateTime.now().toUtc().toIso8601String(),
          "serverClientId": clientID,
          "stats": importStats,
          "serverChanges": outgoingChangeset.toJson(),
        };

        request.response
          ..headers.contentType = ContentType.json
          ..write(safeJsonEncode(responsePayload));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write("Not found");
      }
    } catch (e, stack) {
      debugPrint("Error in LocalSyncServer request: $e\n$stack");
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(safeJsonEncode({"error": e.toString()}));
    } finally {
      await request.response.close();
    }
  }
}
