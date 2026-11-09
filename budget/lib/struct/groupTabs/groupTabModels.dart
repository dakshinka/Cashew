import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class GroupTab {
  final String id;
  String name;
  List<String> members;
  final DateTime createdAt;

  GroupTab({
    String? id,
    required this.name,
    required this.members,
    DateTime? createdAt,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'members': members,
        'createdAt': createdAt.toIso8601String(),
      };

  factory GroupTab.fromJson(Map<String, dynamic> json) => GroupTab(
        id: json['id'] as String?,
        name: json['name'] as String? ?? "Group Tab",
        members: (json['members'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            ["You"],
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'] as String)
            : DateTime.now(),
      );
}

class GroupExpense {
  final String id;
  final String groupTabId;
  String title;
  double amount;
  String paidBy;
  Map<String, double> splitShares; // member -> amount owed
  DateTime date;

  GroupExpense({
    String? id,
    required this.groupTabId,
    required this.title,
    required this.amount,
    required this.paidBy,
    required this.splitShares,
    DateTime? date,
  })  : id = id ?? _uuid.v4(),
        date = date ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'groupTabId': groupTabId,
        'title': title,
        'amount': amount,
        'paidBy': paidBy,
        'splitShares': splitShares,
        'date': date.toIso8601String(),
      };

  factory GroupExpense.fromJson(Map<String, dynamic> json) => GroupExpense(
        id: json['id'] as String?,
        groupTabId: json['groupTabId'] as String? ?? "",
        title: json['title'] as String? ?? "Expense",
        amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
        paidBy: json['paidBy'] as String? ?? "You",
        splitShares: (json['splitShares'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, (v as num).toDouble()),
            ) ??
            {},
        date: json['date'] != null
            ? DateTime.parse(json['date'] as String)
            : DateTime.now(),
      );
}

class DebtSimplificationTransfer {
  final String fromPerson;
  final String toPerson;
  final double amount;

  DebtSimplificationTransfer({
    required this.fromPerson,
    required this.toPerson,
    required this.amount,
  });
}

class DebtSimplifier {
  /// Solves group balances using a greedy min-cash-flow algorithm (O(N log N))
  /// Produces at most N-1 transactions to settle all debts
  static List<DebtSimplificationTransfer> simplify({
    required List<GroupExpense> expenses,
    required List<String> members,
  }) {
    // 1. Calculate net balance for each member
    final Map<String, double> netBalances = {};
    for (final m in members) {
      netBalances[m] = 0.0;
    }

    for (final exp in expenses) {
      // Payer is credited the total amount
      netBalances[exp.paidBy] =
          (netBalances[exp.paidBy] ?? 0.0) + exp.amount;

      // Each participant owes their share
      exp.splitShares.forEach((member, share) {
        netBalances[member] = (netBalances[member] ?? 0.0) - share;
      });
    }

    // 2. Separate into debtors and creditors
    final List<MapEntry<String, double>> debtors = [];
    final List<MapEntry<String, double>> creditors = [];

    netBalances.forEach((person, balance) {
      if (balance < -0.01) {
        debtors.add(MapEntry(person, -balance)); // positive debt amount
      } else if (balance > 0.01) {
        creditors.add(MapEntry(person, balance));
      }
    });

    final List<DebtSimplificationTransfer> transfers = [];

    int d = 0;
    int c = 0;

    while (d < debtors.length && c < creditors.length) {
      final debtor = debtors[d];
      final creditor = creditors[c];

      final double settleAmount =
          debtor.value < creditor.value ? debtor.value : creditor.value;

      if (settleAmount > 0.01) {
        transfers.add(
          DebtSimplificationTransfer(
            fromPerson: debtor.key,
            toPerson: creditor.key,
            amount: settleAmount,
          ),
        );
      }

      debtors[d] = MapEntry(debtor.key, debtor.value - settleAmount);
      creditors[c] = MapEntry(creditor.key, creditor.value - settleAmount);

      if (debtors[d].value <= 0.01) d++;
      if (creditors[c].value <= 0.01) c++;
    }

    return transfers;
  }
}
