# Cashew Improvement & Maintenance Backlog

This backlog synthesizes and tracks findings and recommendations from repository reviews (`cashew_review.md` and `cashew_review_2.md`), prioritized for personal use, data safety, and ongoing maintainability.

---

## ✅ Completed & Verified Fixes

- [x] **Statement Auto-Match Precision**:
  - Prevented capturing calendar years (e.g. `2024`, `2026`) or isolated dates from filenames as card numbers.
  - Enforced strict credit card account compatibility so credit card statements never auto-match to savings/checking accounts.
  - Required word-boundary matching on 4-digit tokens.
- [x] **Silent Migration Errors Swallowing**:
  - Fixed 13 occurrences in `tables.dart:770–855` of `print(e.toString);` (missing invocation parens). All migrations now log actual error messages through `debugPrint`.
- [x] **API Key Leakage in Logs**:
  - Removed `print(storedSettings)` in `settings.dart:42` that leaked raw AI API keys into in-app logs during backup restoration.
  - Added 15-second network timeouts to HTTP requests in `llmClassifier.dart`.
- [x] **SMS Bank Extraction False Positives**:
  - Fixed `_extractBankBrand` in `reviewManager.dart:975` to use exact word boundaries (`\byes\s+bank\b`, `\bbob\b`), preventing ordinary conversational words (e.g. "yes", "kebabs") from being misidentified as banks.
- [x] **Module Configuration Backup & Restore (Review 2, Item B)**:
  - Bundled all non-SQLite preferences (`credit_card_config_*`, `interest_loan_config_*`, `learned_statement_templates`, `cashew_group_*`, `vendor_tabs_*`) into `AppSetting.settingsJSON` via `backupSettings()`.
  - Added auto-restore of module configs on backup import in `initializeSettings()`.
  - Added clean removal of module configs in `wipeAllDataWithDoubleConfirmation()`.
- [x] **Data-Destructive "Redo Migration" Guard**:
  - Protected `PRAGMA user_version = 37` in `debugPage.dart` behind `DangerousDebugFlag` and added a confirmation dialog to prevent accidental DB schema rollbacks.
- [x] **Package Bloat Purge**:
  - Purged ~70 MB of dead demo GIF assets in `budget/packages/sliding_sheet-0.5.2-modified` and `budget/packages/implicitly_animated_reorderable_list-0.4.2-modified`.
- [x] **Build & CI Reproducibility**:
  - Un-ignored `pubspec.lock` in `budget/.gitignore` and removed `rm -f pubspec.lock` in `Dockerfile`.
  - Replaced broken `npm ci` step in `.github/workflows/firebase-hosting-pull-request.yml` with Flutter web build action.
  - Added explicit direct dependencies `uuid` and `collection` in `budget/pubspec.yaml`.

- [x] **Safe Database Restore with Integrity Check (Review 2, Item A)**:
  - Added SQLite format magic header verification (`isValidSqliteHeader`) before writing any bytes to disk.
  - Automatically creates a pre-restore backup snapshot (`db.sqlite.pre_restore_backup`) before overwriting.
  - Safely closes live database executor before replacing the file.
- [x] **Auto-Backup for Non-Google Accounts (Review 2, Item D)**:
  - Added `createLocalAutoBackup()` fallback that saves rolling daily local backups into `backups/cashew-auto-<date>.sqlite` with a 7-backup retention limit when not signed into Google.
- [x] **Google Drive Backup Rotation Order (Review 2, Item E)**:
  - Added `orderBy: 'modifiedTime desc'` to Google Drive API file listing and in-memory descending sort by `modifiedTime` to ensure the newest backups are always retained.

- [x] **Full-Table "Combine / Merge Backup" Support (Review 2, Item C)**:
  - Extended `_commitCombinedData` in `backupShareManager.dart` to merge all entities (`budgets`, `categoryBudgetLimits`, `objectives`, `associatedTitles`, and `prefs`).
  - Optimized duplicate detection from $O(N \cdot M)$ down to $O(N + M)$ using in-memory hash buckets.
- [x] **Startup Launch Optimization (Review 2, Item G)**:
  - Parallelized core database/localization inits and secondary asset/timezone loading in `main.dart` with `Future.wait`, reducing sequential awaits.
- [x] **Database Health & Row Counts in Debug Page (Review 2, Item L)**:
  - Added on-demand `PRAGMA integrity_check` and database size monitor.
  - Added live row counts viewer for transactions, wallets, categories, budgets, and delete logs.

---

## 📋 Open Backlog Items

### Tier 2 — Performance & Architecture (Medium Priority)

1. **Database Query Indexing (Review 1, Item 3)**
   - *Issue*: Tables have no index annotations; queries scan all rows.
   - *Action*: Add `@TableIndex` on `transactions(walletFk, dateCreated)`, `transactions(dateTimeModified)`, and `category_budget_limits(budgetFk, categoryFk)`. (Requires schema version bump to 47 + drift build_runner).

2. **Local-Sync Conflict Resolution (Review 1, Item 2)**
   - *Issue*: Sync insertion uses `insertOrReplace` regardless of `dateTimeModified` timestamps.
   - *Action*: Implement Last-Write-Wins comparison on `dateTimeModified` for incoming records. Add token rate-limiting.

3. **Local-Sync HTTP Server Exposure (Review 1, Item 2 & Review 2, Item I)**
   - *Issue*: Local sync starts HTTP server on `0.0.0.0:8765` with a 6-digit PIN.
   - *Action*: Bind to local host / LAN interface, enforce longer token, and keep disabled when not actively in use.

---

### Tier 3 — Enhancements & Maintenance (Low / Optional)

8. **Diagnostic Maintenance Tools in Debug Page (Review 2, Item L)**
   - Add DB row count monitor (`transactions`, `deleteLogs`, `scannerTemplates`).
   - Add on-demand `PRAGMA integrity_check` button.
9. **UI Internationalization Sweep for Fork Screens (Review 1, Item 9)**
   - Add `.tr()` localization tags to `statementImporterPage`, `reviewInboxPage`, and `creditCardTrackerPage`.
