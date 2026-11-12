// native.dart
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart';
import 'dart:io';

Future<FinanceDatabase> constructDb(String dbName,
    {Uint8List? initialDataWeb}) async {
  // the LazyDatabase util lets us find the right location for the file async.
  final db = LazyDatabase(() async {
    // put the database file, called db.sqlite here, into the documents folder
    // for your app.
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, dbName + '.sqlite'));
    // return NativeDatabase(file);
    QueryExecutor foregroundExecutor = NativeDatabase(file);
    QueryExecutor backgroundExecutor = NativeDatabase.createInBackground(file);
    return MultiExecutor(read: foregroundExecutor, write: backgroundExecutor);
  });
  return FinanceDatabase(db);
}

Future<DBFileInfo> getCurrentDBFileInfo() async {
  Uint8List dbFileBytes;
  late Stream<List<int>> mediaStream;

  final dbFolder = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
  //print("FILE SIZE:" + (dbFile.lengthSync() / 1e+6).toString());
  dbFileBytes = await dbFile.readAsBytes();
  mediaStream = Stream.value(List<int>.from(dbFileBytes));

  return DBFileInfo(dbFileBytes, mediaStream);
}

bool isValidSqliteHeader(Uint8List bytes) {
  if (bytes.length < 16) return false;
  // SQLite format 3\000
  const magic = [
    0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
    0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00
  ];
  for (int i = 0; i < 16; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

Future overwriteDefaultDB(Uint8List dataStore) async {
  if (!isValidSqliteHeader(dataStore)) {
    throw Exception("Selected file is not a valid SQLite database file.");
  }

  final dbFolder = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));

  // Save safety snapshot before overwriting
  if (await dbFile.exists()) {
    try {
      final snapshot = File(p.join(dbFolder.path, 'db.sqlite.pre_restore_backup'));
      await dbFile.copy(snapshot.path);
    } catch (_) {}
  }

  // Close live DB executor connections before writing new database file
  try {
    await database.close();
  } catch (e) {
    print("Notice: live database closed prior to restore: $e");
  }

  await dbFile.writeAsBytes(dataStore);
  // we need to be able to sync with others after the restore
  await sharedPreferences.setString("dateOfLastSyncedWithClient", "{}");
}
