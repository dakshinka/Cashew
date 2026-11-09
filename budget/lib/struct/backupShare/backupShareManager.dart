import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/database/initializeDefaultDatabase.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/localSync/localSyncEngine.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/accountAndBackup.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textWidgets.dart';

const _uuid = Uuid();

/// Helper to get current user/device identifier
String getCurrentUserIdentifier() {
  final user = appStateSettings["username"]?.toString().trim();
  if (user != null && user.isNotEmpty) return user;
  final gUser = googleUser?.displayName?.trim();
  if (gUser != null && gUser.isNotEmpty) return gUser;
  final email = googleUser?.email?.trim();
  if (email != null && email.isNotEmpty) return email;
  return "Local User";
}

enum DuplicateResolution {
  skip,
  keepBoth,
  replace,
}

class DuplicatePair {
  final Transaction existing;
  final Transaction incoming;
  DuplicateResolution resolution;

  DuplicatePair({
    required this.existing,
    required this.incoming,
    this.resolution = DuplicateResolution.skip,
  });
}

class BackupShareManager {
  /// Exports full database as an encrypted or portable .cashew bundle and opens
  /// the system share sheet (WhatsApp, Gmail, Drive, Bluetooth, etc.)
  static Future<void> shareBackupOverWhatsAppOrEmail(
      BuildContext context) async {
    try {
      openSnackbar(
        SnackbarMessage(
          title: "Preparing Backup...",
          description: "Packaging your transactions and accounts",
          icon: Icons.sync,
        ),
      );

      final changeset =
          await LocalSyncEngine.exportChanges(database, null);
      final jsonMap = changeset.toJson();

      final backupBundle = {
        "format": "cashew_backup_v1",
        "exportedAt": DateTime.now().toIso8601String(),
        "exportedBy": getCurrentUserIdentifier(),
        "data": jsonMap,
      };

      final jsonString = jsonEncode(backupBundle);
      final bytes = Uint8List.fromList(utf8.encode(jsonString));

      final dateStr =
          DateFormat("yyyyMMdd_HHmmss").format(DateTime.now());
      final fileName = "Cashew_Backup_$dateStr.cashew";

      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: "application/json",
      );

      await Share.shareXFiles(
        [xFile],
        text:
            "Here is my Cashew finance backup ($dateStr) created by ${getCurrentUserIdentifier()}.",
        subject: "Cashew Backup - $dateStr",
      );
    } catch (e) {
      openSnackbar(
        SnackbarMessage(
          title: "Error Sharing Backup",
          description: e.toString(),
          icon: Icons.error_outline,
        ),
      );
    }
  }

  /// Imports a backup file (.cashew or .json) received from WhatsApp/Email
  /// Detects potential duplicates and presents an interactive resolution dialog
  /// so that data is safely combined without blind overwriting.
  static Future<void> importAndCombineBackup(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) return;

      String fileContent = "";
      if (kIsWeb) {
        final bytes = result.files.single.bytes;
        if (bytes == null) return;
        fileContent = utf8.decode(bytes);
      } else {
        final path = result.files.single.path;
        if (path == null) return;
        final file = File(path);
        fileContent = await file.readAsString();
      }

      final Map<String, dynamic> decoded = jsonDecode(fileContent);
      Map<String, dynamic> dataMap = decoded;
      String senderName = "Incoming Backup";

      if (decoded.containsKey("format") && decoded.containsKey("data")) {
        dataMap = Map<String, dynamic>.from(decoded["data"]);
        senderName = decoded["exportedBy"]?.toString() ?? "Backup";
      }

      final incomingChangeset = LocalSyncChangeset.fromJson(dataMap);
      final existingTransactions = await database.allTransactions;

      final incomingTxns = incomingChangeset.transactions;
      final duplicatePairs = <DuplicatePair>[];
      final nonDuplicateTxns = <Transaction>[];

      for (final incoming in incomingTxns) {
        Transaction? match;
        for (final existing in existingTransactions) {
          // Check matching PK
          if (existing.transactionPk == incoming.transactionPk) {
            match = existing;
            break;
          }
          // Check matching amount, same day, and same title
          final sameAmount =
              (existing.amount.abs() - incoming.amount.abs()).abs() < 0.01;
          final sameDay = existing.dateCreated.year ==
                  incoming.dateCreated.year &&
              existing.dateCreated.month == incoming.dateCreated.month &&
              existing.dateCreated.day == incoming.dateCreated.day;
          final sameName = existing.name.trim().toLowerCase() ==
              incoming.name.trim().toLowerCase();

          if (sameAmount && sameDay && sameName) {
            match = existing;
            break;
          }
        }

        if (match != null) {
          duplicatePairs.add(
            DuplicatePair(existing: match, incoming: incoming),
          );
        } else {
          nonDuplicateTxns.add(incoming);
        }
      }

      // If duplicates detected, show interactive confirmation for each!
      if (duplicatePairs.isNotEmpty) {
        if (!context.mounted) return;
        await _showDuplicateResolutionSheet(
          context: context,
          duplicatePairs: duplicatePairs,
          senderName: senderName,
          onComplete: () async {
            await _commitCombinedData(
              incomingChangeset: incomingChangeset,
              nonDuplicates: nonDuplicateTxns,
              duplicates: duplicatePairs,
              senderName: senderName,
              context: context,
            );
          },
        );
      } else {
        await _commitCombinedData(
          incomingChangeset: incomingChangeset,
          nonDuplicates: nonDuplicateTxns,
          duplicates: duplicatePairs,
          senderName: senderName,
          context: context,
        );
      }
    } catch (e) {
      openSnackbar(
        SnackbarMessage(
          title: "Import Failed",
          description: "Invalid backup format: ${e.toString()}",
          icon: Icons.error_outline,
        ),
      );
    }
  }

  /// Interactive resolution sheet where user explicitly confirms action for each duplicate
  static Future<void> _showDuplicateResolutionSheet({
    required BuildContext context,
    required List<DuplicatePair> duplicatePairs,
    required String senderName,
    required VoidCallback onComplete,
  }) async {
    int currentIndex = 0;

    await openBottomSheet(
      context,
      StatefulBuilder(
        builder: (context, setSheetState) {
          final pair = duplicatePairs[currentIndex];
          final existing = pair.existing;
          final incoming = pair.incoming;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.difference_rounded,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          TextFont(
                            text:
                                "Resolve Duplicate (${currentIndex + 1}/${duplicatePairs.length})",
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ],
                      ),
                      TextFont(
                        text: "From: $senderName",
                        fontSize: 12,
                        textColor: getColor(context, "textLight"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFont(
                    text:
                        "A transaction in the backup matches one already in your database. Confirm how to handle it:",
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                  const SizedBox(height: 16),

                  // Existing Record Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const TextFont(
                              text: "CURRENT ON DEVICE",
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              textColor: Colors.blue,
                            ),
                            TextFont(
                              text: DateFormat("dd MMM yyyy")
                                  .format(existing.dateCreated),
                              fontSize: 12,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        TextFont(
                          text: existing.name,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text: "\$${existing.amount.abs().toStringAsFixed(2)}",
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text:
                              "Entered by: ${existing.transactionOwnerEmail ?? 'You'}",
                          fontSize: 12,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Incoming Record Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextFont(
                              text: "INCOMING FROM $senderName",
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              textColor: Theme.of(context).colorScheme.primary,
                            ),
                            TextFont(
                              text: DateFormat("dd MMM yyyy")
                                  .format(incoming.dateCreated),
                              fontSize: 12,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        TextFont(
                          text: incoming.name,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text: "\$${incoming.amount.abs().toStringAsFixed(2)}",
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text:
                              "Entered by: ${incoming.transactionOwnerEmail ?? senderName}",
                          fontSize: 12,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          child: const Text("Skip"),
                          onPressed: () {
                            pair.resolution = DuplicateResolution.skip;
                            if (currentIndex < duplicatePairs.length - 1) {
                              setSheetState(() => currentIndex++);
                            } else {
                              Navigator.of(context).pop();
                              onComplete();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          child: const Text("Keep Both"),
                          onPressed: () {
                            pair.resolution = DuplicateResolution.keepBoth;
                            if (currentIndex < duplicatePairs.length - 1) {
                              setSheetState(() => currentIndex++);
                            } else {
                              Navigator.of(context).pop();
                              onComplete();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.primary,
                            foregroundColor:
                                Theme.of(context).colorScheme.onPrimary,
                          ),
                          child: const Text("Replace"),
                          onPressed: () {
                            pair.resolution = DuplicateResolution.replace;
                            if (currentIndex < duplicatePairs.length - 1) {
                              setSheetState(() => currentIndex++);
                            } else {
                              Navigator.of(context).pop();
                              onComplete();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Commits non-duplicates and user-confirmed duplicate decisions to SQLite
  static Future<void> _commitCombinedData({
    required LocalSyncChangeset incomingChangeset,
    required List<Transaction> nonDuplicates,
    required List<DuplicatePair> duplicates,
    required String senderName,
    required BuildContext context,
  }) async {
    int importedCount = 0;
    int replacedCount = 0;
    int skippedCount = 0;
    int keptBothCount = 0;

    // 1. Ensure Wallets & Categories exist
    for (final wallet in incomingChangeset.wallets) {
      try {
        await database.createOrUpdateWallet(wallet);
      } catch (_) {}
    }
    for (final cat in incomingChangeset.categories) {
      try {
        await database.createOrUpdateCategory(cat);
      } catch (_) {}
    }

    // 2. Insert non-duplicate transactions
    for (final txn in nonDuplicates) {
      final trackedTxn = txn.copyWith(
        transactionOwnerEmail: Value(
            txn.transactionOwnerEmail ?? senderName),
      );
      await database.createOrUpdateTransaction(trackedTxn, insert: true);
      importedCount++;
    }

    // 3. Process resolved duplicates
    for (final pair in duplicates) {
      if (pair.resolution == DuplicateResolution.skip) {
        skippedCount++;
      } else if (pair.resolution == DuplicateResolution.replace) {
        final updatedTxn = pair.incoming.copyWith(
          transactionPk: pair.existing.transactionPk,
          transactionOwnerEmail: Value(
              pair.incoming.transactionOwnerEmail ?? senderName),
        );
        await database.createOrUpdateTransaction(updatedTxn, insert: false);
        replacedCount++;
      } else if (pair.resolution == DuplicateResolution.keepBoth) {
        final newTxn = pair.incoming.copyWith(
          transactionPk: _uuid.v4(),
          name: "${pair.incoming.name} (from $senderName)",
          transactionOwnerEmail: Value(
              pair.incoming.transactionOwnerEmail ?? senderName),
        );
        await database.createOrUpdateTransaction(newTxn, insert: true);
        keptBothCount++;
      }
    }

    openSnackbar(
      SnackbarMessage(
        title: "Backup Combined Successfully",
        description:
            "Imported: $importedCount, Kept both: $keptBothCount, Replaced: $replacedCount, Skipped: $skippedCount.",
        icon: Icons.check_circle_outline,
      ),
    );
  }

  /// Wipes all test data and re-initializes defaults with double confirmation
  static Future<void> wipeAllDataWithDoubleConfirmation(
      BuildContext context) async {
    // Confirmation 1
    final firstConfirm = await openPopup(
      context,
      icon: Icons.warning_amber_rounded,
      title: "Clear All Data?",
      description:
          "This will permanently delete all transactions, test entries, accounts, and categories on this device.\n\nAre you sure you want to proceed?",
      onCancelLabel: "Cancel",
      onSubmitLabel: "Continue",
      onSubmit: () => popRoute(context, true),
      onCancel: () => popRoute(context, false),
    );

    if (firstConfirm != true) return;

    if (!context.mounted) return;

    // Confirmation 2 (Strict Danger Safeguard)
    final secondConfirm = await openPopup(
      context,
      icon: Icons.delete_forever_rounded,
      title: "FINAL CONFIRMATION",
      description:
          "ALL YOUR DATA WILL BE WIPED IMMEDIATELY.\n\nThis cannot be undone. Tap 'Wipe Everything' to confirm.",
      onCancelLabel: "Cancel",
      onSubmitLabel: "Wipe Everything",
      onSubmit: () => popRoute(context, true),
      onCancel: () => popRoute(context, false),
    );

    if (secondConfirm != true) return;

    // Perform wipe
    try {
      await database.delete(database.transactions).go();
      await database.delete(database.budgets).go();
      await database.delete(database.categoryBudgetLimits).go();
      await database.delete(database.objectives).go();
      await database.delete(database.scannerTemplates).go();
      await database.delete(database.associatedTitles).go();
      await database.delete(database.wallets).go();
      await database.delete(database.categories).go();
      await database.delete(database.deleteLogs).go();

      await initializeDefaultDatabase();

      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "All Data Wiped",
          description: "Database has been reset with clean defaults.",
          icon: Icons.delete_sweep_rounded,
        ),
      );

      // Refresh UI
      homePageStateKey.currentState?.refreshState();
    } catch (e) {
      openSnackbar(
        SnackbarMessage(
          title: "Error Wiping Data",
          description: e.toString(),
          icon: Icons.error_outline,
        ),
      );
    }
  }
}
