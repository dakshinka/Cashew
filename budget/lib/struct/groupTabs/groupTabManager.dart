import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/main.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/groupTabs/groupTabModels.dart';

const _uuid = Uuid();
const String _kGroupTabsStorageKey = "cashew_group_tabs_v1";
const String _kGroupExpensesStorageKey = "cashew_group_expenses_v1";

class GroupTabManager extends ChangeNotifier {
  static final GroupTabManager instance = GroupTabManager._internal();
  GroupTabManager._internal();

  final List<GroupTab> _tabs = [];
  final List<GroupExpense> _expenses = [];
  bool _initialized = false;

  List<GroupTab> get tabs => List.unmodifiable(_tabs);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    try {
      final tabsJson = sharedPreferences.getString(_kGroupTabsStorageKey);
      if (tabsJson != null && tabsJson.isNotEmpty) {
        final List<dynamic> list = jsonDecode(tabsJson);
        _tabs.clear();
        for (final item in list) {
          _tabs.add(GroupTab.fromJson(item as Map<String, dynamic>));
        }
      }

      final expJson = sharedPreferences.getString(_kGroupExpensesStorageKey);
      if (expJson != null && expJson.isNotEmpty) {
        final List<dynamic> list = jsonDecode(expJson);
        _expenses.clear();
        for (final item in list) {
          _expenses.add(GroupExpense.fromJson(item as Map<String, dynamic>));
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint("Error loading group tabs: $e");
    }
  }

  Future<void> _saveToDisk() async {
    try {
      final tabsJson = jsonEncode(_tabs.map((t) => t.toJson()).toList());
      await sharedPreferences.setString(_kGroupTabsStorageKey, tabsJson);

      final expJson = jsonEncode(_expenses.map((e) => e.toJson()).toList());
      await sharedPreferences.setString(_kGroupExpensesStorageKey, expJson);
      notifyListeners();
    } catch (e) {
      debugPrint("Error saving group tabs: $e");
    }
  }

  List<GroupExpense> getExpensesForTab(String tabId) {
    return _expenses.where((e) => e.groupTabId == tabId).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  GroupTab? getTab(String tabId) {
    return _tabs.where((t) => t.id == tabId).firstOrNull;
  }

  Future<GroupTab> createGroup({
    required String name,
    required List<String> members,
  }) async {
    final cleanMembers = members
        .map((m) => m.trim())
        .where((m) => m.isNotEmpty)
        .toSet()
        .toList();

    if (!cleanMembers.contains("You")) {
      cleanMembers.insert(0, "You");
    }

    final newTab = GroupTab(name: name.trim(), members: cleanMembers);
    _tabs.add(newTab);
    await _saveToDisk();
    return newTab;
  }

  Future<void> addExpense({
    required String groupTabId,
    required String title,
    required double amount,
    required String paidBy,
    required Map<String, double> splitShares,
    DateTime? date,
  }) async {
    final exp = GroupExpense(
      groupTabId: groupTabId,
      title: title.trim(),
      amount: amount,
      paidBy: paidBy,
      splitShares: splitShares,
      date: date ?? DateTime.now(),
    );

    _expenses.add(exp);
    await _saveToDisk();
  }

  Future<void> deleteExpense(String expenseId) async {
    _expenses.removeWhere((e) => e.id == expenseId);
    await _saveToDisk();
  }

  Future<void> deleteGroup(String tabId) async {
    _tabs.removeWhere((t) => t.id == tabId);
    _expenses.removeWhere((e) => e.groupTabId == tabId);
    await _saveToDisk();
  }

  /// Settles a debt transfer and logs the transaction into Cashew DB
  Future<bool> settleTransfer({
    required String groupTabId,
    required DebtSimplificationTransfer transfer,
    required String walletPk,
  }) async {
    try {
      final tab = getTab(groupTabId);
      if (tab == null) return false;

      final categories = await database.getAllCategories();
      final catPk = categories.isNotEmpty ? categories.first.categoryPk : "0";

      final bool isOutgoing = transfer.fromPerson == "You";
      final double txAmount =
          isOutgoing ? -transfer.amount.abs() : transfer.amount.abs();

      final String desc = isOutgoing
          ? "Group Tab Settlement to ${transfer.toPerson} (${tab.name})"
          : "Group Tab Settlement from ${transfer.fromPerson} (${tab.name})";

      final tx = Transaction(
        transactionPk: _uuid.v4(),
        name: desc,
        amount: txAmount,
        note: "Settled via Cashew Group Tabs (${tab.name})",
        categoryFk: catPk,
        walletFk: walletPk,
        dateCreated: DateTime.now(),
        income: !isOutgoing,
        paid: true,
        skipPaid: false,
      );

      await database.createOrUpdateTransaction(tx, insert: true);

      // Record compensating settlement expense in the group tab so debt is wiped
      await addExpense(
        groupTabId: groupTabId,
        title: "Settlement: ${transfer.fromPerson} → ${transfer.toPerson}",
        amount: transfer.amount,
        paidBy: transfer.fromPerson,
        splitShares: {transfer.toPerson: transfer.amount},
      );

      return true;
    } catch (e) {
      debugPrint("Error settling group tab transfer: $e");
      return false;
    }
  }
}
