# Cashew — Personal Edition

A personal, privacy-first expense and financial management application built with Flutter, Drift (SQLite), and Material You design.

> **Note**: This repository is a customized personal fork tailored for self-hosted financial tracking, automated statement importing, SMS expense classification, and multi-device local sync without third-party tracking, commercial dependencies, or paywalls.

---

## 🌟 Custom Fork Capabilities

### 1. 📄 Bank Statement Importer (`lib/struct/statementImporter/`)
- **Multi-Format Ingestion**: Supports CSV, TSV, and encrypted or unencrypted PDF bank statements.
- **Smart Column Detection**: Automatic mapping for dates, descriptions, balances, and debit/credit amounts with OCR fallback.
- **Strict Account Auto-Matching**: Enforces account type boundaries (e.g. credit card statements strictly match credit-enabled accounts) and guards against false-positive digit matching (e.g. calendar years like `2024` or `2026`).

### 2. 📨 SMS & Notification Review Inbox (`lib/struct/smsReview/`)
- **Token-Bound Regex Extraction**: Extracts bank brands using word boundaries (`\b`) preventing common word collisions (e.g. "yesterday" vs "yes", "kebabs" vs "bob").
- **Private LLM Categorization**: Optional offline or private LLM assistance (Gemini, Groq, OpenRouter, Ollama) with strict 15-second network timeouts.
- **In-Memory Diagnostics**: Inspect parsing accuracy and rules directly in the app without transmitting SMS payloads externally.

### 3. 💳 Credit Card Billing Tracker (`lib/struct/creditCard/`)
- Tracks billing cycles, statement generation dates, payment due dates, and grace periods.
- Full reconciliation between imported statement totals and active database transactions.

### 4. 🛡️ Data Safety & Rolling Backups (`lib/struct/backupShare/`)
- **Full-Bundle Backups**: Exports the SQLite database along with all non-SQLite preferences (credit card limits, loan terms, and learned statement templates) into a single cohesive payload.
- **Restore Verification**: Validates the 16-byte SQLite magic header (`SQLite format 3\000`), takes an automatic pre-restore safety snapshot (`db.sqlite.pre_restore_backup`), and cleanly closes active connections before file replacement.
- **Offline Auto-Backups**: Rolling daily local backups saved to `backups/cashew-auto-<date>.sqlite` with a 7-day retention limit when not signed into cloud services.

### 5. 🔄 Peer-to-Peer Local Sync (`lib/struct/localSync/`)
- **Last-Write-Wins (LWW)**: Local Wi-Fi sync engine with true timestamp-based conflict resolution using `dateTimeModified`.
- **Hardened Security**: Constant-time XOR token comparison, header-only authentication, and 25 MB stream counters protecting chunked payloads.

---

## ⚙️ Configuration & Feature Flags

Fork-specific behavior is governed by explicit config-as-code constants in [budget/lib/struct/settings.dart](budget/lib/struct/settings.dart):

```dart
/// When true, unlocks all Cashew Pro Lifetime features across the app.
const bool kUnlockAllPro = true;

/// When true, allows accessing the Debug Page in release builds via long-press in About.
const bool kEnableDebugPageInRelease = true;
```

---

## 🛠️ Development & Building

### Prerequisites
- Flutter SDK (>= 3.13.0) & Dart SDK (>= 3.0.0)
- Android SDK (for mobile builds)

### Running Locally
```bash
cd budget
flutter pub get
flutter run
```

### Running Tests
```bash
cd budget
flutter test
```

### Building Android Release APK
```bash
cd budget
flutter build apk --release
# Built APK is located at: budget/build/app/outputs/flutter-apk/app-release.apk
```

### Database Schema Migrations (Drift)
1. Modify tables in `budget/lib/database/tables.dart`.
2. Increment `schemaVersionGlobal` in `tables.dart`.
3. Generate Drift code and schema dump:
   ```bash
   cd budget
   dart run build_runner build --delete-conflicting-outputs
   dart run drift_dev schema dump lib/database/tables.dart drift_schemas/drift_schema_v[version].json
   dart run drift_dev schema steps drift_schemas/ lib/database/schema_versions.dart
   ```
4. Implement migration strategy in `migrator.runMigrationSteps(...)` in `tables.dart`.

---

## 📐 Architecture & Conventions

- **Platform Isolation**: Web target compatibility is preserved via conditional exports in `lib/struct/platformFileUtil/` (`platformFileUtilNative.dart` / `platformFileUtilWeb.dart`) and `lib/struct/localSync/localSyncServer.dart`.
- **Platform Detection**: Always use `getPlatform()` from `functions.dart` rather than raw `Platform` checks to support web and desktop seamlessly.
- **Routing**: Use `pushRoute(context, page)` from `functions.dart` to handle platform-specific navigation transitions.
- **Terminology**:
  - `Wallets` in code are labeled **Accounts** in the UI.
  - `Objectives` in code are labeled **Goals** in the UI.
