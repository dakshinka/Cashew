import 'dart:async';

class LocalSyncServerImplementation {
  static int currentPort = 8765;
  static bool get isRunning => false;

  static String getOrGenerateSecurityToken() => "";
  static void setSecurityToken(String customPin) {}
  static String regenerateSecurityToken() => "";

  static Future<List<String>> getLocalIpAddresses() async {
    return [];
  }

  static Future<bool> startServer({int port = 8765}) async {
    return false;
  }

  static Future<void> stopServer() async {}
}
