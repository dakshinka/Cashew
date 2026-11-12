I'll start by exploring the repository structure to understand what we're working with.Let me dig into the highest-risk areas — the newest fork-specific code (statement importer, SMS/AI, local sync) and the database layer.I have a good picture of the architecture. Now let me verify a few specific suspicions in the highest-risk code paths.Let me verify a few specific claims before writing them up.Let me verify a final set of specifics before writing this up.I have enough evidence. Let me do a final confirmation of a couple of items I'll rank highly.I've completed my investigation. Here is the review — no files were changed.

# Cashew — Repository Review

**Repo:** `dakshinka/Cashew` (Flutter/Drift/Firebase expense tracker, ~147k lines of Dart across 260 files)
**Reviewed at:** `d2d87b2` on `arena/e481dbbd-cashew`

**One caveat up front:** the repo has a single squashed commit ("Auto-match uploaded statements…") against an otherwise upstream codebase, so I reviewed the whole tree, not a diff. I couldn't run the analyzer (no Flutter/Dart in this sandbox), so everything below is from source inspection — I've cited file:line for each claim so you can verify quickly. I've ordered by expected value (data-loss/correctness risk first, then DX).

---

## 1. Statement-import auto-matching will silently attach transactions to the wrong account
`budget/lib/pages/statementImporterPage.dart:53–212`

`_autoMatchAccountIfPossible` is the newest code and the riskiest. Four compounding problems:

- **Credit-card-only strategies run against *every* wallet.** Strategy C (line ~143) correctly filters for credit-card-looking wallets, but strategies A/B/D don't: Strategy B matches on "wallet name contains digits" for any wallet, and Strategy D falls through to `ReviewManager.findMatchingWallet` (`struct/smsReview/reviewManager.dart:900`), whose "substring/contains" step (#4, line ~958) will match an account called *"HDFC Savings"* for a hint of *"HDFC"*.
- **Strategy B's digit check is inverted/broken.** `wDigits.contains(detectedDigits)` where `wDigits` is the *wallet name stripped of everything non-numeric* — so a wallet named "Card" yields `""`, and `"".contains("1234")` is false, but conversely `detectedDigits` (e.g. `"2024"` parsed from a filename) can match a wallet whose name contains those digits for unrelated reasons.
- **Filename-derived digits are treated as a card number.** Line 63 runs `RegExp(r'(?:_|\b)(\d{4})(?:_|\b|\.)')` over the *filename*, which will happily capture the year (`Statement_2024_...`) or a date, then "auto-match" to whichever card ends in 2024.
- **The result is committed without confirmation.** Line 171 `setState` sets `_selectedWalletPk` and line 177 silently rewrites `e.destinationWalletPk` for *every* parsed entry, then shows only a green "Auto-matched to X" notice.

**Why it matters:** every imported transaction gets the wrong `walletFk`. Account balances and net worth go wrong, and because the importer writes deterministic IDs (`assignDeterministicIds`, `statementParser.dart:1362`) the bad data is stable and hard to detect later. At minimum, gate auto-match behind an explicit confirm dialog, restrict credit-card strategies to `CreditCardManager`-enabled wallets, and never derive card digits from the filename.

## 2. Local-sync is last-write-wins by *arrival*, and half its advertised behaviour is unimplemented
`budget/lib/struct/localSync/localSyncEngine.dart:290–430`, `server/localSyncServerNative.dart:120–200`, `localSyncClient.dart:55–145`

- **`importChanges` is not LWW despite the docstring.** Every table uses `InsertMode.insertOrReplace` (lines 306–368) with no `dateTimeModified` comparison, so the *last packet to arrive* wins, not the newest edit. The delete path *does* compare timestamps (`isSmallerOrEqualValue`), which is inconsistent with the insert path. Two-way sync with phone → desktop → phone will lose edits made offline on the slower device.
- `updatedCount` and `skippedCount` (lines 296–298) are declared and returned but never incremented — the UI reports `skipped: 0` always.
- **`fromJson` type dispatch is dead code.** `SyncValueSerializer.fromJson` (`localSyncEngine.dart:25–141`) builds `final typeList = <T>[]` and then tests `typeList is List<DateTime?>` etc. — a runtime `List<T>` of length 0 can only be `List<dynamic>`-compatible, so most of those branches never fire. It works today only because Drift's own serializer handles the common types; the custom enum conversions (`HomePageWidgetDisplay`, `BudgetTransactionFilters`, `MethodAdded`…) will silently fall through to `json as T` and throw on a mismatched enum.
- **The 25 MB payload guard is bypassable.** `request.contentLength > 25 * 1024 * 1024` (`localSyncServerNative.dart:125`) trusts the header; a chunked request has `contentLength == -1`, and the body is then read fully into memory at line ~156 with `utf8.decoder.bind(request).join()`.
- **The PIN is trivially brute-forceable.** `_handleRequest` accepts plain HTTP on `0.0.0.0:8765` with a 6-digit token (`getOrGenerateSecurityToken`, line 32) that's accepted from a **query string** (line ~113) — so it lands in logs/proxies. A custom PIN isn't validated at all: `setSecurityToken` (`localSyncModal` calls it at `widgets/localSyncModal.dart:108`) accepts any non-empty string, including one character. No rate limiting.
- **The server exports its own data back to itself.** `exportChanges` is called on the server (`/api/sync` handler, line ~165) with the *client's* `lastSyncedUtc`, which is fine, but the client then writes `syncTimestampUtc` from the server's clock while `exportChanges` compares `dateTimeModified` values written by *local* clocks — clock skew quietly drops or replays rows.

**Why it matters:** this is the feature users trust with their financial history. Right now it can silently merge two divergent databases. Even just adding a per-row `dateTimeModified` comparison on the insert path and a constant-time token compare would materially de-risk it.

## 3. The database has no indexes and no foreign-key enforcement
`budget/lib/database/tables.dart` (schema definitions), `drift_schema_v46.json`

- **Zero `@TableIndex` declarations anywhere** (confirmed: 0 in `tables.dart`, and `indexes: null` for all 11 entities in the exported schema). Every `watchAllTransactions`, `getAllTransactionsFromWallet`, `getCommonTransactions`, and the local-sync `dateTimeModified >= ?` scans is a full table scan. `getAllTransactionsFromWallet` (`tables.dart:4100`) is called by `checkDuplicates` on *every import*, and `ReviewManager` calls `database.allTransactions` (a full `SELECT *`) at least four separate times (`reviewManager.dart:104, 466, 646`).
- **No `PRAGMA foreign_keys = ON`** anywhere in the codebase. The 16 `references(...)` declarations are decorative — orphaned `categoryFk`/`walletFk` rows are possible, and the code is full of defensive "category no longer exists" workarounds (`tables.dart:3500+`) that exist *because* of this.
- **`DEFAULT_LIMIT = 100000`** (`tables.dart:39`) is effectively "no limit" — `watchAllTransactions` will happily load 100k rows into memory on every change notification.

**Why it matters:** a finance app's cost is dominated by these scans; on a 5-year history this is the difference between a snappy app and a janky one. Adding indexes on `transactions(walletFk, dateCreated)`, `transactions(dateTimeModified)`, `transactions(categoryFk)`, `category_budget_limits(budgetFk, categoryFk)` is a low-risk win — but note it requires a schema bump + `drift_schemas` regeneration (see #7).

## 4. Migrations swallow errors, and `createOrUpdateTransaction` doesn't stamp `dateTimeModified` — which breaks sync in a subtle way
`budget/lib/database/tables.dart:714–870, 3427–3590`

- **13 `catch (e) { print(e.toString); }` blocks in the `onUpgrade` handler** — note `e.toString` *without* the `()` (lines 774, 781, 789, 799, 804, 812, 818, 825, 831, 838, 843, 848, 851). In Dart that prints `Closure: () => String` rather than the error, so a failed `addColumn` is completely invisible. The migration continues, leaving a half-upgraded schema that only fails later at query time.
- **`createOrUpdateTransaction` never sets `dateTimeModified` on the caller's behalf.** I traced the insert: line 3427's function stamps categories and does `copyWith(dateTimeModified: Value(DateTime.now()))` at line ~3578, but that's *after* the `into(transactions).insert(..., mode: insertOrReplace)` at lines 3591–3592? Actually the stamp is applied before the insert (good) — however the **companion default** is `Constant(DateTime.now())`, evaluated when the companion object is *constructed*, not when it's written. For a transaction object built and held (e.g. in the review inbox, then flushed in a batch), `dateTimeModified` is the time the object was created, so sync windows can miss it.
- **`InsertMode.insertOrReplace` on the transactions table is a footgun.** Because the table has FK columns but no enforced FKs, a replace that omits any non-nullable column does a DELETE+INSERT, and there's no `ON DELETE` cascade to clean up dependent rows.

**Why it matters:** silent migration failures are the #1 cause of "my data disappeared after updating". Converting those 13 catches to `rethrow` (or at least `print(e.toString())`) and adding a `schema_migrations` log is a near-zero-risk fix.

## 5. Premium/Pro gating is hard-coded ON — this will be a painful revert if it's meant to be temporary
`budget/lib/struct/settings.dart:78–80`, `budget/lib/struct/defaultPreferences.dart:209`, `widgets/accountAndBackup.dart` / `pages/premiumPage.dart:480, 862, 1404`

```dart
// settings.dart:78
appStateSettings["purchaseID"] = "cashew.pro.lifetime";
```
and the default preference is also `"purchaseID": "cashew.pro.lifetime"` — enforced **after** user settings load, so it can't be overridden. `premiumPage.dart:480` compares against `productIDs["lifetime"]`, which is `cashew.pro.life` on iOS vs `cashew.pro.lifetime` on Android, and `addTransactionPage.dart:625` gates the premium-popup counter on `purchaseID == null`.

**Why it matters:** this fork has disabled monetization for everyone, and it's buried in a settings initializer, not a config flag. If you ever ship to a store, this is a compliance problem; if you don't, all the `in_app_purchase` wiring (`premiumPage.dart`, ~1500 lines, `tryStoreEnabled`) is dead weight — and the whole premium UI is unreachable, so it's untested and will rot. Make it an explicit `bool kFreemiumEnabled = false` constant at the top of `settings.dart` so the intent is obvious.

## 6. API keys are stored in `SharedPreferences` and printed to logs
`budget/lib/pages/reviewInboxPage.dart:1550–1600`, `struct/settings.dart:42, 269`, `struct/smsReview/llmClassifier.dart:95, 218`

- Gemini/Groq/OpenRouter/Ollama keys go through `updateSettings(..., "geminiApiKey", ...)` → `sharedPreferences.setString('userSettings', json.encode(appStateSettings))` — i.e. **one plaintext JSON blob** in Android SharedPreferences / iOS NSUserDefaults / browser localStorage. No `flutter_secure_storage` anywhere in the project (confirmed: 0 imports).
- `settings.dart:42` does `print(storedSettings)` when restoring a backup — **that prints the entire settings JSON, including every API key**, into the log buffer. `logService` (struct/logging.dart) keeps 12,500 entries and the Logs page has a "copy all" button. Anyone who pastes their logs into a bug report leaks their keys.
- `settings.dart:269` `print(appStateSettings["locale"])` is just noise.
- `llmClassifier.dart:114` and `:150` are `http.post` calls with **no `.timeout()`** (the 5 other calls in that file have 8s timeouts) — a hung request blocks SMS review indefinitely with no cancel.

**Why it matters:** these are user-supplied paid API keys. Moving them to secure storage (or at minimum scrubbing known key names before logging) is a small change with a big blast-radius reduction.

## 7. `.gitignore` ignores `.vscode/` but `launch.json` is tracked; `pubspec.lock` is tracked *and* gitignored
`.gitignore:2`, `budget/.gitignore` (last line: `pubspec.lock`), `git ls-files budget/pubspec.lock`

`git check-ignore` confirms `.vscode/launch.json` matches the root ignore rule yet is committed — so every `git status` on a new checkout shows it as a modification, and IDE churn creates noise. Same for `budget/pubspec.lock`: `budget/.gitignore` line ~28 lists `pubspec.lock` as ignored, but the file is tracked and the `Dockerfile` does `rm -f pubspec.lock && flutter pub get` — meaning **CI and local builds resolve different dependency versions**. `pubspec.lock` pins `drift` via sha256 and the SDK floor at Dart `>=3.13.0 / Flutter >=3.44.0`; without it, a fresh `pub get` can pick anything compatible with `drift: ^2.14.0` (i.e. up to `<3.0.0`), and the generated `tables.g.dart` will drift out of sync with the codegen version.

**Why it matters:** this is the classic "works on my machine, fails in Docker/CI" setup. Decide one way: commit the lock (app, not library → yes) and delete the ignore line; and either commit `.vscode` deliberately (un-ignore it) or drop it from the index.

## 8. There is exactly one test, and it cannot pass
`budget/test/widget_test.dart`, `budget/pubspec.yaml:dev_dependencies`

The single test is Flutter's `counter increments smoke test` with the `pumpWidget` line commented out (line 15) — so it taps `Icons.add`, finds nothing, and fails. `flutter_test` isn't even declared in `dev_dependencies` (only `drift_dev` and `build_runner`), so `flutter test` can't resolve it. There is **no CI workflow that runs `flutter analyze` or `flutter test`** — the only workflow (`.github/workflows/firebase-hosting-pull-request.yml`) runs `npm ci && npm run build`, and there is **no `package.json` anywhere in the repo** (confirmed: `find . -name package.json` → nothing), so that workflow fails on every PR.

**Why it matters:** zero test coverage on 147k lines of financial logic. The pure functions are the cheapest wins and need no Flutter runtime: `statementParser.dart` (`parseAmount`, date/2-digit-year handling — note the "auto-heal transactions with year < 100" hack at line 1402, which is a bug *and* a test case), `reviewManager.canonicalizeAccountName` / `findMatchingWallet` / `_extractBankBrand` (line 975 — `lower.contains("yes")` will match "Yesterday"!), `biff8Parser.dart` (a hand-rolled OLE2 parser with `while` loops — perfect for fuzz/property tests), `localSyncEngine` round-trip (serialize → deserialize → expect equal).

`_extractBankBrand` alone deserves a unit test: `if (lower.contains("yes")) return "yes";` (line 988) means the wallet *"Yes Bank"* and a narration *"yes, paid"* collide, and the substring matching in `findMatchingWallet` step 4 has the same issue for short bank names (`BOB`, `AU`, `RBL`).

## 9. New fork features bypass the i18n system entirely
`budget/lib/pages/statementImporterPage.dart` (0 `.tr()` calls, 125 hard-coded user-facing strings), `pages/reviewInboxPage.dart` (0 / 175), `pages/creditCardTrackerPage.dart` (0 / 56), `pages/receiptVaultPage.dart` (0 / 15)

Upstream Cashew ships 20+ locales via `easy_localization` and a 2.2 MB `translations.csv`; every pre-existing page uses `"key".tr()`. All four new screens are 100% English literals. Even the *notice* strings are hard-coded: `"Auto-matched to ${matched.name}"`, `"Created & selected account..."`, `"Authentication Failed: Invalid security token..."`.

**Why it matters:** these are the headline features of this fork, and they're the only part of the app that non-English users can't read. It also means they can never be translated without a rewrite. Establish the rule now (`.tr()` + entry in `translations.csv` + `python generate-translations.py`) before more UI is built on top.

## 10. Cross-platform guards are missing in the new code
`budget/lib/pages/statementImporterPage.dart:5` (`import 'dart:io'`), `struct/backupShare/backupShareManager.dart:2` (`import 'dart:io'`)

Both files import `dart:io` unconditionally but are reachable on web:
- `statementImporterPage.dart` is imported by `widgets/navigationSidebar.dart:7` (rendered everywhere) and uses `File(file.path!)` at line 312 — it `kIsWeb`-guards the bytes read, but the `dart:io` import still breaks the web build *unless* tree-shaking saves it; it's fragile.
- `backupShareManager.dart` imports `dart:io` and is imported by `settingsPage.dart:38`, `addTransactionPage.dart:53`, `reviewManager.dart:14` — all reachable on the PWA build, which `Dockerfile`/`firebase.json` ship.

Compare with the pattern the repo already uses correctly: `struct/localSync/localSyncServer.dart` does `export 'serverWeb.dart' if (dart.library.io) 'serverNative.dart'`, and `database/platform/` has `native.dart` / `web.dart` / `unsupported.dart`. **The new features don't follow the house pattern.**

**Why it matters:** the PWA is a first-class distribution channel (`budget-track.web.app`). A `dart:io` import in a reachable file is the classic "web build compiles but crashes at runtime" bug.

---

## Developer-experience fixes (in priority order)

**DEV-1 — Add `flutter analyze` + `flutter test` CI, and fix the broken Firebase workflow.**
`.github/workflows/firebase-hosting-pull-request.yml` runs `npm ci` with no `package.json`. There's no analysis job at all, despite `budget/analysis_options.yaml` including `package:flutter_lints/flutter.yaml` — **which isn't in `pubspec.yaml` or `pubspec.lock`** (verified: 0 matches). So `analysis_options.yaml`'s `include` currently points at a package that doesn't resolve. A 20-line workflow (`subosito/flutter-action` + `flutter pub get` + `flutter analyze` + `flutter test`) would catch most of the bugs above on every PR. Fix the `package.json` step or delete that workflow.

**DEV-2 — The "Redo migration" debug button is not gated and is data-destructive.**
`budget/lib/pages/debugPage.dart:523`. `DebugPage` is reachable in **release** builds via long-press on the app name in About (`aboutPage.dart:64` — `if (allowDebugFlags)`, and `main.dart:41` sets `bool allowDebugFlags = true` unconditionally). Inside it, the buttons at lines 523–560 (`PRAGMA user_version = 37`, `VACUUM`, `deleteAllDeleteLogs`) sit *outside* the `DangerousDebugFlag` wrapper that the neighboring "Create preview data" button uses (`debugPage.dart:682`). `allowDangerousDebugFlags = kDebugMode` — correct — but these buttons aren't using it. One misplaced long-press by a user, then "Redo migration", and their DB is rolled back to v37 with no backup.

**DEV-3 — ~300 `print()` calls, 40 empty `catch (_) {}` blocks, 13 `print(e.toString)` typos.**
`print` count: 294; `debugPrint`: 62; empty catches: 40. The `print(e.toString)` (no call parens) instances at `tables.dart:774+` are actively hiding errors. Enable `avoid_print` and `empty_catches` in `analysis_options.yaml` (they're in `flutter_lints` once it's actually added) and sweep. In a release build these are all silently dropped on web and noisy on mobile.

**DEV-4 — `budget/packages/` ships 62 MB of `.gif` demo assets for a modified `sliding_sheet` package.**
`budget/packages/sliding_sheet-0.5.2-modified/assets/` contains `example.gif` (13 MB), `parallax_demo.gif` (15 MB), `non_dismissable_demo.gif` (19 MB), etc. The package's `pubspec.yaml` ends with a dangling `flutter:` (no `assets:` key), so **none of these are used**. `implicitly_animated_reorderable_list-0.4.2-modified/assets/` adds 8 MB more. That's ~70 MB of dead weight in every clone. Delete `assets/` from both vendored packages — pure win, zero risk. Also: `value_layout_builder/` is missing its `LICENSE` file while the other two vendored packages have one (relevant given the GPLv3 root license).

**DEV-5 — Broken/incomplete README dev docs.**
`README.md:184` says "not accepting contributions" while PRs are clearly expected; the "Migrate Database" section (line ~230) tells you to "Edit `await stepByStep(...)`" — the actual call is `migrator.runMigrationSteps(...)` (`tables.dart:864`) and the generated file exports `stepByStep(...)`. There's no section on the fork's own new subsystems (`struct/localSync/`, `struct/smsReview/`, `struct/statementImporter/`, `struct/backupShare/`), no guidance on the `web`/`native` conditional-import pattern the new code ignores (#10), and no mention that `.vscode/launch.json` and `pubspec.lock` are tracked despite ignore rules (#7). Also `README` documents `budget/assets/translations/generate-translations.py` correctly — but `scripts/update_translations.bat` has a hard-coded `pause`, making it unusable in CI.

**DEV-6 — Undeclared direct dependencies.**
`uuid` is imported in 12 files, `timezone` in 2, `collection` in 8, `async` in 6, `html` in 1 — **none declared in `pubspec.yaml`** (they arrive transitively). `uuid` is even re-exported globally from `struct/databaseGlobal.dart:6`. `flutter analyze` will flag these as `depend_on_referenced_packages` once lints are on, and a transitive dep bump can remove them without warning. Also, `intl`, `flutter_sticky_header`, `syncfusion_flutter_pdf`, `carousel_slider`, `home_widget`, `material_symbols_icons` are pinned to `any` — one `pub upgrade` can change any of them.

---

## Summary table

| # | Area | Files | Why it matters |
|---|---|---|---|
| 1 | Import auto-match misassigns accounts | `statementImporterPage.dart:53–212`, `reviewManager.dart:900` | Silent wrong-account attribution; corrupt balances |
| 2 | Local sync is not LWW; dead serializer branches | `localSyncEngine.dart`, `localSyncServerNative.dart` | Data loss across devices; wrong reported stats |
| 3 | No DB indexes, no FK enforcement, limit=100k | `tables.dart:39, 4100`, schema v46 | Full scans on every screen; orphan rows |
| 4 | Swallowed migrations; `dateTimeModified` defaults at construction | `tables.dart:714–870, 3427+` | Half-migrated DBs; sync windows miss rows |
| 5 | Premium gating hard-coded on | `settings.dart:78`, `defaultPreferences.dart:209` | Store-compliance risk; dead premium UI rots |
| 6 | API keys in SharedPreferences + printed to logs | `reviewInboxPage.dart:1550+`, `settings.dart:42` | Key leakage via bug-report logs |
| 7 | Ignore/track conflicts (`.vscode`, `pubspec.lock`) | `.gitignore`, `budget/.gitignore`, `Dockerfile` | Non-reproducible builds |
| 8 | One un-runnable test; no analysis/test CI | `test/widget_test.dart`, `.github/workflows/` | Zero regression safety on 147k LOC |
| 9 | New screens bypass i18n | 4 new pages, 0 `.tr()` | 20+ locales can't read the new features |
| 10 | `dart:io` in web-reachable files | `statementImporterPage.dart:5`, `backupShareManager.dart:2` | PWA build fragility |

**If you only fix three things:** #4 (silent migration failures — cheapest, highest data-safety payoff), #8 (CI + a handful of parser unit tests — enables everything else), and #1 (confirm-before-auto-match — stops the newest code from corrupting accounts).

Everything above is read-only; I haven't modified any files. Tell me which items you want and I'll implement them on this branch.