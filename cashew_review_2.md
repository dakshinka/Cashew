Good — for personal use the priority order shifts. Let me check a few things I skipped, since backup safety, restore verification, and maintenance tooling matter far more when there's no support team.

This is a significant lead — let me check whether the fork's new features store data outside the database.

Let me verify a few last details on the personal-use danger zones: where receipt images live, and how Drive backup retention works.

I have what I need. Here are suggestions only — I haven't changed anything.

# Additional improvements for personal use

Personal use changes the calculus: **you are the only user, the only QA, and the only recovery path.** So the things that matter are the ones that can silently destroy or fragment your data, plus the ones that make your own daily use worse. Everything below is either read-only or a small, contained change.

---

## Tier 1 — Data-loss and data-fragmentation risks (fix these first)

### A. Restore never closes the live database or checks the file
`budget/lib/widgets/importDB.dart:39–46`, `budget/lib/database/platform/native.dart:43–50`

Restore is `overwriteDefaultDB(fileBytes)` → `dbFile.writeAsBytes(dataStore)` on a database that is **still open** (`LateDatabase`/`MultiExecutor` in `native.dart:8–20` is never closed on this path). On web the same thing happens via `overwriteDefaultDB` in `database/platform/web.dart:48`. There is also:
- **no `PRAGMA integrity_check`**
- **no schema-version check** — a v33 file dropped onto a v46 build, or vice versa, is only caught later by `onUpgrade`/`onCreate` throwing
- **no "save current data first" snapshot** before the overwrite
- **no size/type validation** at all — the only gate is the *filename* extension warning (`importDB.dart:34–40`), and it's a warning, not a check

**Why it matters personally:** a bad restore is unrecoverable. You'd be overwriting your only copy of the file. Minimum viable fix: close the DB → `integrity_check` → compare `user_version` against `schemaVersionGlobal` (46) and refuse/report mismatch → only then write. Ten lines.

### B. The fork's new features store data *outside* the database — so backups lose it
This is the single biggest personal-use trap in this repo. Every one of these lives in `SharedPreferences`, **not** in the SQLite file:

| Feature | Storage | File |
|---|---|---|
| Credit-card configs (limit, last4, statement/due dates, grace period) | `credit_card_config_<walletPk>` | `struct/creditCard/creditCardManager.dart:28, 42` |
| Interest/loan configs | `interest_loan_config_<objectivePk>` | `struct/loans/interestLoanManager.dart:15, 50` |
| Group tabs + group expenses | `cashew_group_tabs_v1`, `cashew_group_expenses_v1` | `struct/groupTabs/groupTabManager.dart:10–11` |
| Daily services / vendor tabs | `vendor_tabs_daily_services` | `struct/vendorTabs/vendorTabManager.dart:12` |
| Receipt vault | `cashew_receipt_vault_v1` | `struct/receiptVault/receiptManager.dart:7` |
| Learned statement templates | `learned_statement_templates` | `struct/statementImporter/statementTemplate.dart:187` |
| Review inbox cache | `cached_review_transactions_v1` | `struct/smsReview/reviewManager.dart:20` |
| SMS diagnostic logs (300 entries of raw SMS) | `cached_sms_diagnostic_logs_v1` | `struct/smsReview/smsDiagnosticTracker.dart:8` |
| SMS→account bindings | inside `userSettings` JSON | `reviewManager.dart:34` |

I grepped for every one of these keys outside its own manager — **zero hits.** That means:
- `ExportDB` (`widgets/exportDB.dart`) copies only `db.sqlite` → your credit-card limits, group tabs, receipts and learned statement templates are **not in the backup**.
- `saveDBFileToDevice` calls `backupSettings()` (`exportDB.dart:17–21` → `settings.dart:326`) which only writes *user settings*, not these keys.
- The `.cashew` share path (`shareBackupOverWhatsAppOrEmail`) exports only `LocalSyncEngine` tables — it doesn't even call `backupSettings()`.
- `wipeAllDataWithDoubleConfirmation` (`backupShareManager.dart:559–570`) deletes DB tables and re-runs `initializeDefaultDatabase()`, but **leaves every one of these preference blobs intact** — so "wipe all data" leaves orphaned credit-card configs keyed to wallet PKs that no longer exist.

**Suggestions (pick one, all cheap):**
1. Add a single `SharedPreferencesGateway.exportAll()` / `restoreAll()` that dumps every `cashew_*`, `credit_card_config_*`, `interest_loan_config_*`, `learned_statement_templates`, `vendor_tabs_*` key into the backup bundle as a sibling to the DB. This is the correct long-term fix.
2. Cheaper stopgap: on `ExportDB`, print a prominent warning listing which features aren't backed up, and add those keys to the `.cashew` bundle JSON under a `"prefs"` key.
3. Regardless: make "Wipe all data" clear those keys too, or you'll get phantom credit-card configs after a wipe.

### C. The "Combine / Merge Backup" restore is lossy and ad-verified as complete
`budget/lib/struct/backupShare/backupShareManager.dart:454–520`, UI text at `pages/settingsPage.dart:744–756`

The `.cashew` bundle is exported with a `"format": "cashew_backup_v1"` envelope and described in the UI as *"Send your complete finance backup"*. But `_commitCombinedData` only imports **wallets, categories, and transactions** (lines 466–477 — I confirmed `incomingChangeset.` appears exactly twice in that function). **Budgets, goals/objectives, category spending limits, associated titles, delete logs, and credit-card configs are dropped.**

Worse, the duplicate detection is O(n·m) over **all existing transactions** (`line 146: database.allTransactions`) with an inner loop per incoming txn — on 5k×5k that's 25M comparisons on the UI isolate, plus `sameAmount && sameDay && sameName` will flag legitimately identical-looking transactions as duplicates and prompt you for each one.

**Why it matters personally:** if you ever use this to merge your phone and desktop, you'll quietly lose budgets and goals while the app tells you it succeeded. Either fix the commit path to insert all tables, or relabel the feature to "merge transactions and accounts only."

### D. Auto-backup is off by default for anyone not signed into Google
`budget/lib/widgets/accountAndBackup.dart:304`, `struct/defaultPreferences.dart:139`

```dart
Future<void> createBackupInBackground(context) async {
  if (appStateSettings["hasSignedIn"] == false) return;   // ← hard exit
```
`hasSignedIn` defaults to `false`. So if you never sign in to Google, **`autoBackups: true` + `autoBackupsFrequency: 3` never fire.** The settings UI will happily show auto-backup as enabled (`accountAndBackup.dart:903`) while nothing backs up. For pure-local use this should either fall back to writing a timestamped `.sqlite` next to the DB (or to a user-chosen folder) — or the toggle should be disabled with an explanation.

### E. Drive rotation can delete more than you expect
`widgets/accountAndBackup.dart:496–508`

`deleteRecentBackups(context, appStateSettings["backupLimit"], ...)` with `backupLimit: 20` — and it's called from three places, including `accountsPage.dart:235` with `deleteOldBackups: true`. Sync files (`sync-<clientID>.sqlite`) are protected by `isSyncBackupFile`, good. But manual share/backup files all share the pattern `db-v<schema>-<device>.sqlite`, and rotation keeps only the newest 20 **by whatever order `files.list` returns** (no `orderBy`, line 491) — you can lose your oldest good backup before your newest bad one. Add `$orderBy: 'modifiedTime desc'` and treat the first successful restore as a reason to keep a "golden" copy.

### F. There is no integrity/health check anywhere, and schema validation is commented out
`database/tables.dart:706–712`

```dart
// beforeOpen: (details) async {
//   try { await validateDatabaseSchema(); } catch (e) { print("Database mismatch " + ...); }
```
Drift ships exactly the tool you need (`validateDatabaseSchema()` from `drift_dev/api/migrations`) and it's disabled. For a single-user app, running it in a **debug-only** build (`kDebugMode`) on every launch would catch a broken migration the same day instead of months later. Pair with the `PRAGMA integrity_check` from (A) on startup and expose both as one button in the debug page.

---

## Tier 2 — Make your own daily use better

### G. Daily-driver: the startup path does ~10 sequential awaits before first frame
`budget/lib/main.dart:45–78`

`Firebase.initializeApp` (wrapped in try/catch — good) → `EasyLocalization.ensureInitialized` → `SharedPreferences` → `constructDb` → `initializeNotifications` → `loadCurrencyJSON` → `loadLanguageNamesJSON` → `initializeSettings` → `tz.initializeTimeZones` → `FlutterTimezone.getLocalTimezone`. `initializeSettings()` alone parses the whole settings blob and runs `attemptToMigrateSetLongTermLoansAmountTo0()`. For personal use this is the difference between "opens instantly" and "1.5s spinner." Two easy wins: (1) skip Firebase entirely when `hasSignedIn == false` (you're not using shared budgets), and (2) `Future.wait` the three asset/prefs loads that don't depend on each other.

### H. `settings.dart:42` prints your whole settings JSON — including API keys — on every backup restore
Confirmed: `print(storedSettings);` inside the restore path, and `logService` (struct/logging.dart) keeps 12,500 lines with a "copy all" button in the Logs page. For personal use this is mostly self-harm, but if you ever paste logs into an issue, your Gemini/Groq/OpenRouter keys go with them. One-line fix: delete line 42 (and `settings.dart:269`).

### I. Turn off the features you don't use — they're the ones carrying risk
Given `SMS review`, `statement import`, and `local sync` are the riskiest code (#1–#2 in my earlier review), for personal use the highest-leverage "improvement" may be **not running them**:
- `localSync` starts an HTTP server on `0.0.0.0:8765` with a 6-digit PIN and `Access-Control-Allow-Origin: *` (`localSyncServerNative.dart:104, 110`). If you only sync phone↔desktop on your home Wi-Fi, bind to the LAN interface and require a longer token; if you don't use it, `stopServer()` on launch so it's never listening.
- `emailScanning` is gated behind `DangerousDebugFlag` (kDebugMode only) at `debugPage.dart:682` — good. Keep it off.
- `notificationScanningDebug` (`debugPage.dart:302`) is a plain toggle, not gated. That one lets a `notification_listener_service` read every notification on the device. For personal use, decide deliberately whether you want it.

### J. Config-as-code: make your fork's intent explicit instead of hard-coded
Two magic values control your whole experience and are buried:
- `settings.dart:80` + `defaultPreferences.dart:209` force `purchaseID = "cashew.pro.lifetime"` — i.e. all Pro features unlocked, applied *after* settings load so it can't be overridden.
- `main.dart:41` `allowDebugFlags = true` in release → the debug page (including the un-gated `PRAGMA user_version = 37` button at `debugPage.dart:523` that rolls your DB back to v37) is reachable by long-pressing the app name in About.

For personal use, make these two named constants at the top of `main.dart` (`const bool kUnlockAllPro = true; const bool kEnableDebugPage = false;`) so a future `flutter build --release` doesn't carry a one-long-press data-loss button. It also makes it obvious what you changed if you ever rebase off upstream.

### K. `budget/pubspec.lock` is tracked but git-ignored; builds aren't reproducible
`budget/.gitignore` lists `pubspec.lock`, yet the file is committed (`git ls-files` confirms) and `Dockerfile:10` does `rm -f pubspec.lock && flutter pub get`. For personal use this means your Docker/PWA build and your local build can resolve **different `drift` versions** — and `drift` version drift against a generated `tables.g.dart` produces exactly the kind of migration bug that eats data. Remove the ignore line and drop the `rm -f` from the Dockerfile.

### L. Cheap maintenance tools worth adding to the debug page
You already have `VACUUM`, `deleteAllDeleteLogs`, and `fixTransactionPolarity` there. For personal use, add three more:
1. **DB size + row counts** (`transactions`, `deleteLogs`, `scannerTemplates`) — `deleteLogs` is never pruned automatically (`grep` shows only `deleteAllDeleteLogs` in the debug page), so it grows forever.
2. **`PRAGMA integrity_check` + `validateDatabaseSchema()`** (see F).
3. **A "dry-run restore"** that opens a chosen backup file in a *separate* `FinanceDatabase( NativeDatabase.memory() )` and reports row counts before you commit to overwriting.

### M. Backups: the one habit that matters most
Given (A) and (B), for personal use the practical advice is: **keep an offline `.sqlite` copy you control**, taken with the app fully closed, and *verify it restores* at least once. `ExportDB` is the right button — but it won't include the prefs-backed features in (B), so also keep a copy of the app's `SharedPreferences` XML/plist if you care about credit-card limits and group tabs. If you want, I can sketch exactly what a "complete backup" would need to include and where each piece lives.

---

## What I'd skip for personal use

- **i18n sweep (#9 earlier)** — hard-coding English is fine if you only read English. Low value unless you want to hand the app to someone.
- **Indexes (#3)** — still worth doing, but not urgent until your history gets large; measure first with the row-count tool from (L).
- **The `dart:io` web-safety work (#10)** — only matters if you actually use the PWA. If you're mobile-only, ignore it.
- **LWW sync correctness (#2)** — becomes urgent the day you start using sync; until then, don't enable local sync and the problem can't bite you.

**The three I'd actually do:** (A) safe restore, (B) get the prefs-backed feature data into backups, (J) make the pro-unlock/debug-page constants explicit. Those are the ones where a single bad day costs you years of transaction history.

No files were modified. Say the word and I'll implement any of these on `arena/e481dbbd-cashew`.