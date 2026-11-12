import 'dart:io';
import 'dart:typed_data';

/// Read file bytes from a local native file path
Future<Uint8List> readFileBytesFromPath(String path) async {
  return await File(path).readAsBytes();
}

/// Read file string from a local native file path
Future<String> readFileStringFromPath(String path) async {
  return await File(path).readAsString();
}
