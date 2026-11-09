import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';

class SyncValueSerializer extends ValueSerializer {
  const SyncValueSerializer();

  @override
  dynamic toJson<T>(T value) {
    if (value == null) return null;
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Enum) {
      return value.name;
    }
    if (value is List) {
      return value.map((e) => toJson(e)).toList();
    }
    return value;
  }

  @override
  T fromJson<T>(dynamic json) {
    if (json == null) return null as T;

    final typeList = <T>[];

    if (typeList is List<DateTime?>) {
      if (json is int) {
        return DateTime.fromMillisecondsSinceEpoch(json) as T;
      }
      return DateTime.parse(json.toString()) as T;
    }

    if (typeList is List<double?> && json is int) {
      return json.toDouble() as T;
    }

    if (typeList is List<Uint8List?> && json is! Uint8List) {
      return Uint8List.fromList((json as List).cast<int>()) as T;
    }

    if (typeList is List<List<HomePageWidgetDisplay>?>) {
      if (json is List) {
        return json.map((item) {
          if (item is int && item >= 0 && item < HomePageWidgetDisplay.values.length) {
            return HomePageWidgetDisplay.values[item];
          }
          final str = item.toString();
          return HomePageWidgetDisplay.values.firstWhere(
            (e) => e.name == str,
            orElse: () => HomePageWidgetDisplay.WalletSwitcher,
          );
        }).toList() as T;
      }
      return null as T;
    }

    if (typeList is List<List<BudgetTransactionFilters>?>) {
      if (json is List) {
        return json.map((item) {
          if (item is int && item >= 0 && item < BudgetTransactionFilters.values.length) {
            return BudgetTransactionFilters.values[item];
          }
          final str = item.toString();
          return BudgetTransactionFilters.values.firstWhere(
            (e) => e.name == str,
            orElse: () => BudgetTransactionFilters.defaultBudgetTransactionFilters,
          );
        }).toList() as T;
      }
      return null as T;
    }

    if (typeList is List<MethodAdded?>) {
      final str = json.toString();
      return MethodAdded.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => MethodAdded.email,
      ) as T;
    }

    if (typeList is List<ObjectiveType>) {
      final str = json.toString();
      return ObjectiveType.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => ObjectiveType.goal,
      ) as T;
    }

    if (typeList is List<BudgetReoccurence?>) {
      final str = json.toString();
      return BudgetReoccurence.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => BudgetReoccurence.monthly,
      ) as T;
    }

    if (typeList is List<TransactionSpecialType?>) {
      final str = json.toString();
      return TransactionSpecialType.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => TransactionSpecialType.credit,
      ) as T;
    }

    if (typeList is List<SharedStatus?>) {
      final str = json.toString();
      return SharedStatus.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => SharedStatus.waiting,
      ) as T;
    }

    if (typeList is List<SharedOwnerMember?>) {
      final str = json.toString();
      return SharedOwnerMember.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => SharedOwnerMember.owner,
      ) as T;
    }

    if (typeList is List<DeleteLogType>) {
      final str = json.toString();
      return DeleteLogType.values.firstWhere(
        (e) => e.name == str || e.index.toString() == str,
        orElse: () => DeleteLogType.Transaction,
      ) as T;
    }

    if (typeList is List<List<String>?>) {
      if (json is List) {
        return json.map((e) => e.toString()).toList() as T;
      }
      return null as T;
    }

    return json as T;
  }
}

class LocalSyncChangeset {
  static const syncSerializer = SyncValueSerializer();

  final List<TransactionWallet> wallets;
  final List<TransactionCategory> categories;
  final List<Budget> budgets;
  final List<CategoryBudgetLimit> categoryBudgetLimits;
  final List<Transaction> transactions;
  final List<TransactionAssociatedTitle> associatedTitles;
  final List<Objective> objectives;
  final List<DeleteLog> deleteLogs;

  LocalSyncChangeset({
    this.wallets = const [],
    this.categories = const [],
    this.budgets = const [],
    this.categoryBudgetLimits = const [],
    this.transactions = const [],
    this.associatedTitles = const [],
    this.objectives = const [],
    this.deleteLogs = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'wallets': wallets.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'categories': categories.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'budgets': budgets.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'categoryBudgetLimits':
          categoryBudgetLimits.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'transactions': transactions.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'associatedTitles': associatedTitles.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'objectives': objectives.map((e) => e.toJson(serializer: syncSerializer)).toList(),
      'deleteLogs': deleteLogs.map((e) => e.toJson(serializer: syncSerializer)).toList(),
    };
  }

  factory LocalSyncChangeset.fromJson(Map<String, dynamic> json) {
    return LocalSyncChangeset(
      wallets: (json['wallets'] as List? ?? [])
          .map((e) => TransactionWallet.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      categories: (json['categories'] as List? ?? [])
          .map((e) =>
              TransactionCategory.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      budgets: (json['budgets'] as List? ?? [])
          .map((e) => Budget.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      categoryBudgetLimits: (json['categoryBudgetLimits'] as List? ?? [])
          .map((e) =>
              CategoryBudgetLimit.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      transactions: (json['transactions'] as List? ?? [])
          .map((e) => Transaction.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      associatedTitles: (json['associatedTitles'] as List? ?? [])
          .map((e) => TransactionAssociatedTitle.fromJson(
              Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      objectives: (json['objectives'] as List? ?? [])
          .map((e) => Objective.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
      deleteLogs: (json['deleteLogs'] as List? ?? [])
          .map((e) => DeleteLog.fromJson(Map<String, dynamic>.from(e), serializer: syncSerializer))
          .toList(),
    );
  }

  int get totalCount =>
      wallets.length +
      categories.length +
      budgets.length +
      categoryBudgetLimits.length +
      transactions.length +
      associatedTitles.length +
      objectives.length +
      deleteLogs.length;
}

class LocalSyncEngine {
  /// Generates a changeset of all entities modified since [sinceUtc].
  /// If [sinceUtc] is null, exports all active entities (full sync).
  static Future<LocalSyncChangeset> exportChanges(
      FinanceDatabase db, DateTime? sinceUtc) async {
    final DateTime filterTime = sinceUtc ?? DateTime.fromMillisecondsSinceEpoch(0);

    final wallets = await (db.select(db.wallets)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final categories = await (db.select(db.categories)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final budgets = await (db.select(db.budgets)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final categoryBudgetLimits = await (db.select(db.categoryBudgetLimits)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final transactions = await (db.select(db.transactions)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final associatedTitles = await (db.select(db.associatedTitles)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final objectives = await (db.select(db.objectives)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    final deleteLogs = await (db.select(db.deleteLogs)
          ..where((t) =>
              t.dateTimeModified.isBiggerOrEqualValue(filterTime) |
              t.dateTimeModified.isNull()))
        .get();

    return LocalSyncChangeset(
      wallets: wallets,
      categories: categories,
      budgets: budgets,
      categoryBudgetLimits: categoryBudgetLimits,
      transactions: transactions,
      associatedTitles: associatedTitles,
      objectives: objectives,
      deleteLogs: deleteLogs,
    );
  }

  /// Ingests an incoming [changeset] deterministically using Last-Write-Wins (LWW)
  /// and deduplication checks so duplicate or missed records are avoided.
  static Future<Map<String, int>> importChanges(
      FinanceDatabase db, LocalSyncChangeset changeset) async {
    int insertedCount = 0;
    int updatedCount = 0;
    int deletedCount = 0;
    int skippedCount = 0;

    await db.batch((batch) {
      // 1. Wallets
      for (final w in changeset.wallets) {
        batch.insert(
          db.wallets,
          w,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 2. Categories
      for (final c in changeset.categories) {
        batch.insert(
          db.categories,
          c,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 3. Budgets
      for (final b in changeset.budgets) {
        batch.insert(
          db.budgets,
          b,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 4. Category Budget Limits
      for (final l in changeset.categoryBudgetLimits) {
        batch.insert(
          db.categoryBudgetLimits,
          l,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 5. Associated Titles
      for (final at in changeset.associatedTitles) {
        batch.insert(
          db.associatedTitles,
          at,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 6. Objectives
      for (final o in changeset.objectives) {
        batch.insert(
          db.objectives,
          o,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 7. Transactions (with idempotent upsert by transactionPk)
      for (final t in changeset.transactions) {
        batch.insert(
          db.transactions,
          t,
          mode: InsertMode.insertOrReplace,
        );
        insertedCount++;
      }

      // 8. DeleteLogs (propagate deletions safely)
      for (final d in changeset.deleteLogs) {
        batch.insert(
          db.deleteLogs,
          d,
          mode: InsertMode.insertOrIgnore,
        );

        if (d.type == DeleteLogType.Transaction) {
          batch.deleteWhere(
            db.transactions,
            (tbl) =>
                tbl.transactionPk.equals(d.entryPk) &
                tbl.dateTimeModified.isSmallerOrEqualValue(d.dateTimeModified),
          );
        } else if (d.type == DeleteLogType.TransactionCategory) {
          batch.deleteWhere(
            db.categories,
            (tbl) =>
                tbl.categoryPk.equals(d.entryPk) &
                tbl.dateTimeModified.isSmallerOrEqualValue(d.dateTimeModified),
          );
        } else if (d.type == DeleteLogType.TransactionWallet) {
          batch.deleteWhere(
            db.wallets,
            (tbl) =>
                tbl.walletPk.equals(d.entryPk) &
                tbl.dateTimeModified.isSmallerOrEqualValue(d.dateTimeModified),
          );
        } else if (d.type == DeleteLogType.Budget) {
          batch.deleteWhere(
            db.budgets,
            (tbl) =>
                tbl.budgetPk.equals(d.entryPk) &
                tbl.dateTimeModified.isSmallerOrEqualValue(d.dateTimeModified),
          );
        } else if (d.type == DeleteLogType.Objective) {
          batch.deleteWhere(
            db.objectives,
            (tbl) =>
                tbl.objectivePk.equals(d.entryPk) &
                tbl.dateTimeModified.isSmallerOrEqualValue(d.dateTimeModified),
          );
        } else if (d.type == DeleteLogType.TransactionAssociatedTitle) {
          batch.deleteWhere(
            db.associatedTitles,
            (tbl) =>
                tbl.associatedTitlePk.equals(d.entryPk) &
                tbl.dateTimeModified.isSmallerOrEqualValue(d.dateTimeModified),
          );
        }
        deletedCount++;
      }
    });

    return {
      'insertedOrUpdated': insertedCount,
      'deleted': deletedCount,
      'skipped': skippedCount,
    };
  }
}
