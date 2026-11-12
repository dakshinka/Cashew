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

---

## 📋 Open Backlog Items

### Tier 1 — Data Safety & Restore Integrity (High Priority)

1. **Safe Database Restore with Integrity Check (Review 2, Item A)**
   - *Issue*: Restoring a backup currently writes bytes directly to `db.sqlite` while SQLite connection is still open. No `PRAGMA integrity_check` or schema version pre-validation.
   - *Action*: Close existing database executor before overwriting, verify SQLite header/integrity, and compare `user_version` against `schemaVersionGlobal` (46).

2. **Full-Table "Combine / Merge Backup" Support (Review 2, Item C)**
   - *Issue*: `_commitCombinedData` in `backupShareManager.dart` only merges wallets, categories, and transactions. Budgets, objectives/goals, and limits are omitted.
   - *Action*: Extend changeset importer to merge all tables, or clearly label in UI as "Merge Accounts & Transactions". Optimize duplicate checking lookup.

3. **Auto-Backup for Non-Google Accounts (Review 2, Item D)**
   - *Issue*: `createBackupInBackground` hard-exits if `hasSignedIn == false`.
   - *Action*: For local-only use without Google Drive, enable auto-backup to write periodic snapshot copies into local storage.

4. **Google Drive Backup Rotation Order (Review 2, Item E)**
   - *Issue*: `deleteRecentBackups` prunes old backups using default Drive API ordering (which is non-deterministic without `orderBy: 'modifiedTime desc'`).
   - *Action*: Pass explicit sorting by `modifiedTime desc` before trimming to the 20-backup limit.

---

### Tier 2 — Performance & Architecture (Medium Priority)

5. **Database Query Indexing (Review 1, Item 3)**
   - *Issue*: Tables have no index annotations; queries scan all rows.
   - *Action*: Add `@TableIndex` on `transactions(walletFk, dateCreated)`, `transactions(dateTimeModified)`, and `category_budget_limits(budgetFk, categoryFk)`. (Requires schema version bump to 47 + drift build_runner).

6. **Local-Sync Conflict Resolution (Review 1, Item 2)**
   - *Issue*: Sync insertion uses `insertOrReplace` regardless of `dateTimeModified` timestamps.
   - *Action*: Implement Last-Write-Wins comparison on `dateTimeModified` for incoming records. Add token rate-limiting.

7. **Startup Optimization (Review 2, Item G)**
   - *Issue*: ~10 sequential awaits before first frame.
   - *Action*: Skip Firebase initialization when signed out; parallelize static asset loading (`loadCurrencyJSON`, `loadLanguageNamesJSON`, `tz.initializeTimeZones`).

---

### Tier 3 — Enhancements & Maintenance (Low / Optional)

8. **Diagnostic Maintenance Tools in Debug Page (Review 2, Item L)**
   - Add DB row count monitor (`transactions`, `deleteLogs`, `scannerTemplates`).
   - Add on-demand `PRAGMA integrity_check` button.
9. **UI Internationalization Sweep for Fork Screens (Review 1, Item 9)**
   - Add `.tr()` localization tags to `statementImporterPage`, `reviewInboxPage`, and `creditCardTrackerPage`.
