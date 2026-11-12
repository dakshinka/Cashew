# Project Guidelines & Coding Standards for Cashew

All autonomous agents, contributors, and scripts working in this repository must strictly adhere to these standards:

---

## 1. Database & Persistence Standards (Drift / SQLite)
* **Migrations**: Never swallow errors in `onUpgrade` with empty catches or uncalled methods (`print(e.toString);`). Always log full error output or rethrow.
* **Indexes & Foreign Keys**: All new foreign keys and search query columns must have indexed coverage. Keep `PRAGMA foreign_keys = ON;` active in `beforeOpen`.
* **State Cohesion**: Features that store metadata in `SharedPreferences` (e.g. credit card configs, loan configs, learned statement templates) **must** register their backup keys with `backupSettings()` and restore handlers in `initializeSettings()`.
* **Safe Restores**: Always validate SQLite magic headers (`isValidSqliteHeader`) and create a safety backup before overwriting `db.sqlite`.

---

## 2. Ingestion & Account Resolution (Statement Importer / SMS Review)
* **No Ambiguous Identifiers**: Never parse calendar years (`2024`, `2026`) or dates as card numbers.
* **Account Type Isolation**: Credit card statement imports must only match credit-enabled wallets (`CreditCardConfig.isEnabled`), never savings or checking accounts.
* **Bank Matching Boundaries**: Use regex word boundaries (`\b`) when matching short bank identifiers (`hdfc`, `sbi`, `yes bank`, `bob`) to prevent common word collisions.
* **User Control**: Target account auto-matching must always be clearly indicated in the UI with a 1-tap override/selection capability.

---

## 3. Security, Network & Secrets
* **No Secret Logging**: Never log raw settings objects or backups containing user API keys (`geminiApiKey`, `groqApiKey`, `openRouterApiKey`).
* **HTTP Timeouts**: All outbound API/LLM calls must enforce a `.timeout(const Duration(seconds: 15))`.
* **Local Sync Protocol**: Never pass security tokens in URL query strings. Use constant-time XOR comparison for tokens. Stream payloads with a strict 25 MB cap.

---

## 4. Cross-Platform & Repository Hygiene
* **Web Compatibility**: Do not import `dart:io` in shared UI files without `kIsWeb` guards or conditional exports.
* **Reproducible Builds**: Never delete `pubspec.lock` in Dockerfiles or CI. Always keep `pubspec.lock` tracked in Git.
* **Package Cleanliness**: Do not commit unreferenced demo assets or large GIF files in vendored packages under `budget/packages/`.
