import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum DuplicateState {
  unique,
  potentialDuplicate,
  confirmedDuplicate,
}

class StatementEntry {
  final String id;
  DateTime date;
  String rawNarration;
  String cleanMerchant;
  double amount;
  bool isIncome;
  String? referenceNo;
  double? balance;
  String suggestedCategoryName;
  String? suggestedCategoryPk;
  double confidence;
  bool isSelected;
  DuplicateState duplicateState;
  String? duplicateReason;

  StatementEntry({
    String? id,
    required this.date,
    required this.rawNarration,
    required this.cleanMerchant,
    required this.amount,
    required this.isIncome,
    this.referenceNo,
    this.balance,
    required this.suggestedCategoryName,
    this.suggestedCategoryPk,
    this.confidence = 0.85,
    this.isSelected = true,
    this.duplicateState = DuplicateState.unique,
    this.duplicateReason,
  }) : id = id ?? _uuid.v4();
}

class StatementColumnIndices {
  int dateCol;
  int narrationCol;
  int? amountCol;
  int? debitCol;
  int? creditCol;
  int? typeCol;
  int? refCol;
  int? balanceCol;
  int headerRowIndex;

  StatementColumnIndices({
    this.dateCol = -1,
    this.narrationCol = -1,
    this.amountCol,
    this.debitCol,
    this.creditCol,
    this.typeCol,
    this.refCol,
    this.balanceCol,
    this.headerRowIndex = 0,
  });

  bool get isValid =>
      dateCol >= 0 &&
      narrationCol >= 0 &&
      (amountCol != null || (debitCol != null || creditCol != null));
}
