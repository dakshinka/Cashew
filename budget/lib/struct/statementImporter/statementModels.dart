import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum DuplicateState {
  unique,
  potentialDuplicate,
  confirmedDuplicate,
}

class StatementEntry {
  String id;
  DateTime date;
  String rawNarration;
  String cleanMerchant;
  double amount;
  bool isIncome;
  String? referenceNo;
  double? balance;
  String suggestedCategoryName;
  String? suggestedCategoryPk;
  String? suggestedSubCategoryName;
  String? suggestedSubCategoryPk;
  double confidence;
  bool isSelected;
  DuplicateState duplicateState;
  String? duplicateReason;

  // User control & cash reconciliation fields
  bool isCashWithdrawal;
  bool isTransferToCash;
  String? destinationWalletPk;
  bool isUserReviewed;
  String? matchedSource;

  // Credit card specific fields
  bool isCreditCardInterest;
  bool isCreditCardGst;
  bool isCreditCardEmi;

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
    this.suggestedSubCategoryName,
    this.suggestedSubCategoryPk,
    this.confidence = 0.85,
    this.isSelected = true,
    this.duplicateState = DuplicateState.unique,
    this.duplicateReason,
    this.isCashWithdrawal = false,
    this.isTransferToCash = false,
    this.destinationWalletPk,
    this.isUserReviewed = false,
    this.matchedSource,
    this.isCreditCardInterest = false,
    this.isCreditCardGst = false,
    this.isCreditCardEmi = false,
  }) : id = id ?? _uuid.v4();
}

class CreditCardStatementSummary {
  final DateTime? statementDate;
  final DateTime? dueDate;
  final double? totalAmountDue;
  final double? minAmountDue;
  final double? creditLimit;
  final double? availableCredit;
  final double? financeCharges;
  final double? gstCharges;
  final List<String> emiSummaries;

  CreditCardStatementSummary({
    this.statementDate,
    this.dueDate,
    this.totalAmountDue,
    this.minAmountDue,
    this.creditLimit,
    this.availableCredit,
    this.financeCharges,
    this.gstCharges,
    this.emiSummaries = const [],
  });

  bool get hasData =>
      statementDate != null ||
      dueDate != null ||
      totalAmountDue != null ||
      financeCharges != null ||
      emiSummaries.isNotEmpty;
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
