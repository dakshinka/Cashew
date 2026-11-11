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
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/localSync/localSyncEngine.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/accountAndBackup.dart';
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
  final email = googleUser?.email.trim();
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

  /// Purges ONLY transaction entries from the database with confirmation,
  /// preserving all accounts, categories, budgets, and settings.
  static Future<void> purgeOnlyTransactionsWithConfirmation(
    BuildContext context, {
    String? targetWalletPk,
    String? targetWalletName,
  }) async {
    final isSpecificWallet =
        targetWalletPk != null && targetWalletPk.isNotEmpty;
    final accountDesc = isSpecificWallet
        ? "from account '${targetWalletName ?? targetWalletPk}'"
        : "across ALL accounts";

    final confirm = await openPopup(
      context,
      icon: Icons.delete_sweep_rounded,
      title: "Purge Transactions Only?",
      description:
          "This will permanently delete all transaction records $accountDesc.\n\nYour accounts/wallets, categories, budgets, and settings will remain completely intact.\n\nAre you sure you want to proceed?",
      onCancelLabel: "Cancel",
      onSubmitLabel: "Purge Transactions",
      onSubmit: () => popRoute(context, true),
      onCancel: () => popRoute(context, false),
    );

    if (confirm != true) return;

    try {
      int deletedCount = 0;
      if (isSpecificWallet) {
        deletedCount = await (database.delete(database.transactions)
              ..where((t) => t.walletFk.equals(targetWalletPk)))
            .go();
      } else {
        deletedCount = await database.delete(database.transactions).go();
      }

      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "Transactions Purged",
          description:
              "Removed $deletedCount transaction entries $accountDesc.",
          icon: Icons.check_circle_outline_rounded,
        ),
      );

      // Refresh home and navigation state
      homePageStateKey.currentState?.refreshState();
    } catch (e) {
      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "Error Purging Transactions",
          description: e.toString(),
          icon: Icons.error_outline,
        ),
      );
    }
  }

  /// Scans the database for duplicate transactions, presents the findings to the user,
  /// and safely deletes duplicate copies while preserving the earliest original entry.
  static Future<void> findAndRemoveDuplicatesWithConfirmation(
    BuildContext context, {
    String? targetWalletPk,
    String? targetWalletName,
  }) async {
    final isSpecificWallet =
        targetWalletPk != null && targetWalletPk.isNotEmpty;
    final accountDesc = isSpecificWallet
        ? "in account '${targetWalletName ?? targetWalletPk}'"
        : "across all accounts";

    // 1. Fetch transactions
    List<Transaction> txns;
    if (isSpecificWallet) {
      txns = await database.getAllTransactionsFromWallet(targetWalletPk);
    } else {
      txns = await database.allTransactions;
    }

    if (txns.isEmpty) {
      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "No Transactions Found",
          description: "There are no transactions to check $accountDesc.",
          icon: Icons.info_outline,
        ),
      );
      return;
    }

    // Sort chronologically (earliest first so original is preserved)
    txns.sort((a, b) => a.dateCreated.compareTo(b.dateCreated));

    // 2. Identify duplicate groups
    final List<String> duplicatePksToDelete = [];
    final Set<String> processedPks = {};

    for (int i = 0; i < txns.length; i++) {
      final t1 = txns[i];
      if (processedPks.contains(t1.transactionPk)) continue;

      final t1DateOnly = DateTime(
          t1.dateCreated.year, t1.dateCreated.month, t1.dateCreated.day);

      for (int j = i + 1; j < txns.length; j++) {
        final t2 = txns[j];
        if (processedPks.contains(t2.transactionPk)) continue;

        // Must be in same wallet and same type (income/expense)
        if (t1.walletFk != t2.walletFk || t1.income != t2.income) continue;

        // Amount must match
        if ((t1.amount.abs() - t2.amount.abs()).abs() >= 0.01) continue;

        // Date check: identical calendar day or within 1 day
        final t2DateOnly = DateTime(
            t2.dateCreated.year, t2.dateCreated.month, t2.dateCreated.day);
        final diffDays = t1DateOnly.difference(t2DateOnly).inDays.abs();
        if (diffDays > 1) continue;

        final name1 = t1.name.toLowerCase().trim();
        final name2 = t2.name.toLowerCase().trim();
        final note1 = t1.note.toLowerCase().trim();
        final note2 = t2.note.toLowerCase().trim();

        bool isDuplicate = false;

        // Exact match on name or note
        if (name1 == name2 && (diffDays == 0 || note1 == note2)) {
          isDuplicate = true;
        } else if (name1.contains(name2) || name2.contains(name1)) {
          isDuplicate = true;
        } else if (note1.isNotEmpty &&
            note2.isNotEmpty &&
            (note1 == note2 || note1.contains(note2) || note2.contains(note1))) {
          isDuplicate = true;
        }

        if (isDuplicate) {
          // Keep t1 as the original, mark t2 for deletion
          processedPks.add(t2.transactionPk);
          duplicatePksToDelete.add(t2.transactionPk);
        }
      }
    }

    if (duplicatePksToDelete.isEmpty) {
      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "No Duplicates Found",
          description: "All transactions $accountDesc are unique.",
          icon: Icons.check_circle_outline_rounded,
        ),
      );
      return;
    }

    if (!context.mounted) return;

    final confirm = await openPopup(
      context,
      icon: Icons.find_replace_rounded,
      title: "Remove ${duplicatePksToDelete.length} Duplicates?",
      description:
          "Found ${duplicatePksToDelete.length} duplicate transactions $accountDesc.\n\nCashew will keep the earliest original entry for each transaction and delete only the duplicate copies.\n\nProceed to remove duplicates?",
      onCancelLabel: "Cancel",
      onSubmitLabel: "Delete Duplicates",
      onSubmit: () => popRoute(context, true),
      onCancel: () => popRoute(context, false),
    );

    if (confirm != true) return;

    try {
      final deleted = await (database.delete(database.transactions)
            ..where((t) => t.transactionPk.isIn(duplicatePksToDelete)))
          .go();

      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "Duplicates Removed",
          description: "Successfully deleted $deleted duplicate transactions.",
          icon: Icons.check_circle_outline_rounded,
        ),
      );

      // Refresh home and navigation state
      homePageStateKey.currentState?.refreshState();
    } catch (e) {
      if (!context.mounted) return;
      openSnackbar(
        SnackbarMessage(
          title: "Error Deleting Duplicates",
          description: e.toString(),
          icon: Icons.error_outline,
        ),
      );
    }
  }
}
