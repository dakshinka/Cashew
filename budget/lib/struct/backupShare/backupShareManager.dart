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
import 'package:budget/struct/statementImporter/statementParser.dart';
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

      final Map<String, String> persistedConfigs = {};
      for (final key in sharedPreferences.getKeys()) {
        if (key.startsWith("credit_card_config_") ||
            key.startsWith("interest_loan_config_") ||
            key.startsWith("cashew_") ||
            key.startsWith("vendor_tabs_") ||
            key == "learned_statement_templates") {
          final val = sharedPreferences.getString(key);
          if (val != null) persistedConfigs[key] = val;
        }
      }

      final backupBundle = {
        "format": "cashew_backup_v1",
        "exportedAt": DateTime.now().toIso8601String(),
        "exportedBy": getCurrentUserIdentifier(),
        "data": jsonMap,
        "prefs": persistedConfigs,
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

      // Restore bundled module configurations (credit card configs, templates, loans)
      if (decoded.containsKey("prefs") && decoded["prefs"] is Map) {
        final prefsMap = decoded["prefs"] as Map;
        for (final entry in prefsMap.entries) {
          if (entry.key is String && entry.value is String) {
            await sharedPreferences.setString(
                entry.key as String, entry.value as String);
          }
        }
      }

      final incomingChangeset = LocalSyncChangeset.fromJson(dataMap);
      final existingTransactions = await database.allTransactions;

      final incomingTxns = incomingChangeset.transactions;
      final duplicatePairs = <DuplicatePair>[];
      final nonDuplicateTxns = <Transaction>[];

      // Fast O(1) indexing of existing transactions
      final existingByPk = <String, Transaction>{};
      final existingByBucket = <String, List<Transaction>>{};

      for (final existing in existingTransactions) {
        existingByPk[existing.transactionPk] = existing;
        final d = existing.dateCreated;
        final bucket =
            "${d.year}_${d.month}_${d.day}_${existing.amount.abs().toStringAsFixed(2)}";
        (existingByBucket[bucket] ??= []).add(existing);
      }

      for (final incoming in incomingTxns) {
        Transaction? match = existingByPk[incoming.transactionPk];
        if (match == null) {
          final d = incoming.dateCreated;
          final bucket =
              "${d.year}_${d.month}_${d.day}_${incoming.amount.abs().toStringAsFixed(2)}";
          final candidates = existingByBucket[bucket];
          if (candidates != null) {
            final inName = incoming.name.trim().toLowerCase();
            for (final c in candidates) {
              if (c.name.trim().toLowerCase() == inName) {
                match = c;
                break;
              }
            }
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

    // 2. Ensure Budgets & Category Budget Limits exist
    for (final budget in incomingChangeset.budgets) {
      try {
        await database.createOrUpdateBudget(budget);
      } catch (_) {}
    }
    for (final limit in incomingChangeset.categoryBudgetLimits) {
      try {
        await database.into(database.categoryBudgetLimits).insert(
              limit,
              mode: InsertMode.insertOrReplace,
            );
      } catch (_) {}
    }

    // 3. Ensure Objectives / Goals & Associated Titles exist
    for (final objective in incomingChangeset.objectives) {
      try {
        await database.createOrUpdateObjective(objective);
      } catch (_) {}
    }
    for (final title in incomingChangeset.associatedTitles) {
      try {
        await database.createOrUpdateAssociatedTitle(title);
      } catch (_) {}
    }

    // 4. Insert non-duplicate transactions
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

      // Clear all module preferences to avoid orphaned configs
      for (final key in sharedPreferences.getKeys().toList()) {
        if (key.startsWith("credit_card_config_") ||
            key.startsWith("interest_loan_config_") ||
            key.startsWith("cashew_") ||
            key.startsWith("vendor_tabs_") ||
            key == "learned_statement_templates") {
          await sharedPreferences.remove(key);
        }
      }

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
  /// and allows side-by-side review before safely deleting duplicate copies.
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
    final List<TransactionDuplicateReviewPair> duplicatePairs = [];
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

        // Date check: identical calendar day or within 1 day (or up to 5 days if Ref IDs match)
        final t2DateOnly = DateTime(
            t2.dateCreated.year, t2.dateCreated.month, t2.dateCreated.day);
        final diffDays = t1DateOnly.difference(t2DateOnly).inDays.abs();

        // Check Reference IDs if present
        final ref1 = StatementParser.extractReferenceId(t1.note);
        final ref2 = StatementParser.extractReferenceId(t2.note);
        final refsMatch = StatementParser.areReferenceIdsMatching(ref1, ref2) ||
            StatementParser.notesShareReferenceId(t1.note, t2.note);

        if (ref1 != null &&
            ref2 != null &&
            ref1.isNotEmpty &&
            ref2.isNotEmpty) {
          if (!refsMatch) {
            // Different reference IDs on same day: separate legitimate payments!
            continue;
          }
        }

        // For transactions with matching reference IDs, allow up to 5 days difference
        // (due to weekend/holiday bank clearing vs real-time SMS)
        if (refsMatch) {
          if (diffDays > 5) continue;
        } else {
          if (diffDays > 1) continue;
        }

        final name1 = t1.name.toLowerCase().trim();
        final name2 = t2.name.toLowerCase().trim();
        final note1 = t1.note.toLowerCase().trim();
        final note2 = t2.note.toLowerCase().trim();

        bool isDuplicate = false;
        String reason = "";

        if (refsMatch) {
          isDuplicate = true;
          final matchedRef = (ref1 != null && ref1.isNotEmpty)
              ? StatementParser.normalizeReferenceId(ref1)
              : ((ref2 != null && ref2.isNotEmpty)
                  ? StatementParser.normalizeReferenceId(ref2)
                  : "");
          reason = "Matching Ref / Txn ID: '$matchedRef'";
        } else if (name1 == name2 && (diffDays == 0 || note1 == note2)) {
          isDuplicate = true;
          reason = "Identical merchant & amount on same day";
        } else if (name1.contains(name2) || name2.contains(name1)) {
          isDuplicate = true;
          reason = "Merchant similarity with matching amount & date";
        } else if (note1.isNotEmpty &&
            note2.isNotEmpty &&
            (note1 == note2 || note1.contains(note2) || note2.contains(note1))) {
          isDuplicate = true;
          reason = "Matching narration notes & amount";
        }

        if (isDuplicate) {
          processedPks.add(t2.transactionPk);
          duplicatePairs.add(
            TransactionDuplicateReviewPair(
              original: t1,
              duplicate: t2,
              reason: reason,
              userChoice: 'keepOriginal',
            ),
          );
        }
      }
    }

    if (duplicatePairs.isEmpty) {
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

    // 3. Open Interactive Side-by-Side Review Bottom Sheet
    await openBottomSheet(
      context,
      StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.find_replace_rounded,
                      color: Theme.of(sheetContext).colorScheme.primary,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFont(
                            text: "Review Duplicates (${duplicatePairs.length})",
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          TextFont(
                            text:
                                "Compare suspected duplicates side-by-side before deleting.",
                            fontSize: 12,
                            textColor: getColor(sheetContext, "textLight"),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),

                // List of duplicate pairs
                Expanded(
                  child: ListView.builder(
                    itemCount: duplicatePairs.length,
                    itemBuilder: (ctx, idx) {
                      final pair = duplicatePairs[idx];
                      final orig = pair.original;
                      final dup = pair.duplicate;

                      final ref1 = StatementParser.extractReferenceId(orig.note);
                      final ref2 = StatementParser.extractReferenceId(dup.note);
                      final amtStr =
                          "${orig.amount < 0 ? '-' : '+'}₹${orig.amount.abs().toStringAsFixed(2)}";

                      String getSourceTag(String note) {
                        if (note.contains("[Source: Bank Statement")) return "Bank Statement";
                        if (note.contains("[Source: Credit Card")) return "Card Statement";
                        if (note.contains("[Source: SMS")) return "SMS";
                        return "Recorded";
                      }
                      final src1 = getSourceTag(orig.note);
                      final src2 = getSourceTag(dup.note);

                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: getColor(sheetContext, "canvasContainer"),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: getColor(sheetContext, "dividerColor")
                                .withOpacity(0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header: Amount & Flag Reason
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextFont(
                                  text: amtStr,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  textColor: orig.income
                                      ? Colors.green.shade700
                                      : Theme.of(sheetContext)
                                          .colorScheme
                                          .onSurface,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: TextFont(
                                    text: pair.reason,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    textColor: Colors.amber.shade900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            // Side-by-Side Candidates Comparison
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Candidate A (Original)
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: pair.userChoice == 'keepOriginal'
                                          ? Colors.green.withOpacity(0.08)
                                          : (pair.userChoice == 'keepBoth'
                                              ? Colors.blue.withOpacity(0.05)
                                              : Colors.red.withOpacity(0.05)),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: pair.userChoice == 'keepOriginal'
                                            ? Colors.green.shade400
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              pair.userChoice == 'keepOriginal'
                                                  ? Icons.check_circle_rounded
                                                  : Icons.radio_button_unchecked,
                                              size: 14,
                                              color: pair.userChoice ==
                                                      'keepOriginal'
                                                  ? Colors.green.shade700
                                                  : Colors.grey,
                                            ),
                                            const SizedBox(width: 4),
                                            TextFont(
                                              text: "Candidate A",
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            const Spacer(),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 4, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: src1 == "Bank Statement"
                                                    ? Colors.blue.withOpacity(0.15)
                                                    : (src1 == "SMS"
                                                        ? Colors.purple.withOpacity(0.15)
                                                        : Colors.grey.withOpacity(0.15)),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: TextFont(
                                                text: src1,
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w600,
                                                textColor: src1 == "Bank Statement"
                                                    ? Colors.blue.shade800
                                                    : (src1 == "SMS"
                                                        ? Colors.purple.shade800
                                                        : Colors.grey.shade700),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        TextFont(
                                          text: orig.name,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          maxLines: 1,
                                        ),
                                        TextFont(
                                          text: DateFormat("dd MMM, hh:mm a")
                                              .format(orig.dateCreated),
                                          fontSize: 10,
                                          textColor: getColor(
                                              sheetContext, "textLight"),
                                        ),
                                        if (ref1 != null) ...[
                                          const SizedBox(height: 2),
                                          TextFont(
                                            text: "Ref: $ref1",
                                            fontSize: 10,
                                            textColor: Colors.blue.shade800,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // Candidate B (Duplicate)
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: pair.userChoice == 'keepDuplicate'
                                          ? Colors.green.withOpacity(0.08)
                                          : (pair.userChoice == 'keepBoth'
                                              ? Colors.blue.withOpacity(0.05)
                                              : Colors.red.withOpacity(0.05)),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: pair.userChoice == 'keepDuplicate'
                                            ? Colors.green.shade400
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              pair.userChoice == 'keepDuplicate'
                                                  ? Icons.check_circle_rounded
                                                  : Icons.radio_button_unchecked,
                                              size: 14,
                                              color: pair.userChoice ==
                                                      'keepDuplicate'
                                                  ? Colors.green.shade700
                                                  : Colors.grey,
                                            ),
                                            const SizedBox(width: 4),
                                            TextFont(
                                              text: "Candidate B",
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            const Spacer(),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 4, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: src2 == "Bank Statement"
                                                    ? Colors.blue.withOpacity(0.15)
                                                    : (src2 == "SMS"
                                                        ? Colors.purple.withOpacity(0.15)
                                                        : Colors.grey.withOpacity(0.15)),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: TextFont(
                                                text: src2,
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w600,
                                                textColor: src2 == "Bank Statement"
                                                    ? Colors.blue.shade800
                                                    : (src2 == "SMS"
                                                        ? Colors.purple.shade800
                                                        : Colors.grey.shade700),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        TextFont(
                                          text: dup.name,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          maxLines: 1,
                                        ),
                                        TextFont(
                                          text: DateFormat("dd MMM, hh:mm a")
                                              .format(dup.dateCreated),
                                          fontSize: 10,
                                          textColor: getColor(
                                              sheetContext, "textLight"),
                                        ),
                                        if (ref2 != null) ...[
                                          const SizedBox(height: 2),
                                          TextFont(
                                            text: "Ref: $ref2",
                                            fontSize: 10,
                                            textColor: Colors.blue.shade800,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),

                            // Resolution Choice Pills
                            Row(
                              children: [
                                Expanded(
                                  child: ChoiceChip(
                                    label: const TextFont(
                                        text: "Keep A", fontSize: 11),
                                    selected: pair.userChoice == 'keepOriginal',
                                    onSelected: (_) {
                                      setSheetState(() {
                                        pair.userChoice = 'keepOriginal';
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: ChoiceChip(
                                    label: const TextFont(
                                        text: "Keep B", fontSize: 11),
                                    selected: pair.userChoice == 'keepDuplicate',
                                    onSelected: (_) {
                                      setSheetState(() {
                                        pair.userChoice = 'keepDuplicate';
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: ChoiceChip(
                                    label: const TextFont(
                                        text: "Keep Both", fontSize: 11),
                                    selected: pair.userChoice == 'keepBoth',
                                    onSelected: (_) {
                                      setSheetState(() {
                                        pair.userChoice = 'keepBoth';
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),

                // Confirm CTA Button
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(sheetContext, "canvasContainer"),
                        textColor: getColor(sheetContext, "black"),
                        onTap: () => Navigator.of(sheetContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: Button(
                        label: "Apply Resolutions",
                        icon: Icons.done_all_rounded,
                        color: Theme.of(sheetContext).colorScheme.primary,
                        textColor:
                            Theme.of(sheetContext).colorScheme.onPrimary,
                        onTap: () async {
                          Navigator.of(sheetContext).pop();

                          final List<String> toDelete = [];
                          for (final p in duplicatePairs) {
                            if (p.userChoice == 'keepOriginal') {
                              toDelete.add(p.duplicate.transactionPk);
                            } else if (p.userChoice == 'keepDuplicate') {
                              toDelete.add(p.original.transactionPk);
                            }
                            // 'keepBoth': do not delete either
                          }

                          if (toDelete.isEmpty) {
                            openSnackbar(
                              SnackbarMessage(
                                title: "No Changes Applied",
                                description:
                                    "All duplicate pairs marked to keep both.",
                                icon: Icons.info_outline,
                              ),
                            );
                            return;
                          }

                          try {
                            final deleted = await (database.delete(
                                    database.transactions)
                                  ..where((t) => t.transactionPk.isIn(toDelete)))
                                .go();

                            if (!context.mounted) return;
                            openSnackbar(
                              SnackbarMessage(
                                title: "Duplicates Resolved",
                                description:
                                    "Removed $deleted duplicate transactions.",
                                icon: Icons.check_circle_outline_rounded,
                              ),
                            );

                            homePageStateKey.currentState?.refreshState();
                          } catch (e) {
                            if (!context.mounted) return;
                            openSnackbar(
                              SnackbarMessage(
                                title: "Error Resolving Duplicates",
                                description: e.toString(),
                                icon: Icons.error_outline,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class TransactionDuplicateReviewPair {
  final Transaction original;
  final Transaction duplicate;
  final String reason;
  String userChoice;

  TransactionDuplicateReviewPair({
    required this.original,
    required this.duplicate,
    required this.reason,
    this.userChoice = 'keepOriginal',
  });
}
