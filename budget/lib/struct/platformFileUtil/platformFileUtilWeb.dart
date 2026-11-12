import 'dart:typed_data';

/// On web, path-based access is not available; file.bytes must be used.
Future<Uint8List> readFileBytesFromPath(String path) async {
  throw UnsupportedError("File paths are not supported on web");
}

/// On web, path-based access is not available; file.bytes must be used.
Future<String> readFileStringFromPath(String path) async {
  throw UnsupportedError("File paths are not supported on web");
}
