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
  final String? billingPeriod;
  final String? cardName;
  final String? cardLast4;
  final double? totalAmountDue;
  final double? minAmountDue;
  final double? previousStatementDue;
  final double? paymentsReceived;
  final double? purchasesCurrentCycle;
  final double? financeCharges;
  final double? gstCharges;
  final double? totalCreditLimit;
  final double? availableCreditLimit;
  final double? availableCashLimit;
  final List<String> emiSummaries;
  final String? extractedVia; // "template:<name>", "llm", "deterministic"

  CreditCardStatementSummary({
    this.statementDate,
    this.dueDate,
    this.billingPeriod,
    this.cardName,
    this.cardLast4,
    this.totalAmountDue,
    this.minAmountDue,
    this.previousStatementDue,
    this.paymentsReceived,
    this.purchasesCurrentCycle,
    this.financeCharges,
    this.gstCharges,
    double? totalCreditLimit,
    double? creditLimit,
    double? availableCreditLimit,
    double? availableCredit,
    this.availableCashLimit,
    this.emiSummaries = const [],
    this.extractedVia,
  })  : totalCreditLimit = totalCreditLimit ?? creditLimit,
        availableCreditLimit = availableCreditLimit ?? availableCredit;

  // Backward compatible alias
  double? get creditLimit => totalCreditLimit;
  double? get availableCredit => availableCreditLimit;

  bool get hasData =>
      statementDate != null ||
      dueDate != null ||
      totalAmountDue != null ||
      previousStatementDue != null ||
      purchasesCurrentCycle != null ||
      totalCreditLimit != null ||
      financeCharges != null ||
      emiSummaries.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'statementDate': statementDate?.toIso8601String(),
        'dueDate': dueDate?.toIso8601String(),
        'billingPeriod': billingPeriod,
        'cardName': cardName,
        'cardLast4': cardLast4,
        'totalAmountDue': totalAmountDue,
        'minAmountDue': minAmountDue,
        'previousStatementDue': previousStatementDue,
        'paymentsReceived': paymentsReceived,
        'purchasesCurrentCycle': purchasesCurrentCycle,
        'financeCharges': financeCharges,
        'gstCharges': gstCharges,
        'totalCreditLimit': totalCreditLimit,
        'availableCreditLimit': availableCreditLimit,
        'availableCashLimit': availableCashLimit,
        'emiSummaries': emiSummaries,
        'extractedVia': extractedVia,
      };

  factory CreditCardStatementSummary.fromJson(Map<String, dynamic> json) =>
      CreditCardStatementSummary(
        statementDate: json['statementDate'] != null
            ? DateTime.tryParse(json['statementDate'] as String)
            : null,
        dueDate: json['dueDate'] != null
            ? DateTime.tryParse(json['dueDate'] as String)
            : null,
        billingPeriod: json['billingPeriod'] as String?,
        cardName: json['cardName'] as String?,
        cardLast4: json['cardLast4'] as String?,
        totalAmountDue: (json['totalAmountDue'] as num?)?.toDouble(),
        minAmountDue: (json['minAmountDue'] as num?)?.toDouble(),
        previousStatementDue:
            (json['previousStatementDue'] as num?)?.toDouble(),
        paymentsReceived: (json['paymentsReceived'] as num?)?.toDouble(),
        purchasesCurrentCycle:
            (json['purchasesCurrentCycle'] as num?)?.toDouble(),
        financeCharges: (json['financeCharges'] as num?)?.toDouble(),
        gstCharges: (json['gstCharges'] as num?)?.toDouble(),
        totalCreditLimit: (json['totalCreditLimit'] as num?)?.toDouble(),
        availableCreditLimit:
            (json['availableCreditLimit'] as num?)?.toDouble(),
        availableCashLimit: (json['availableCashLimit'] as num?)?.toDouble(),
        emiSummaries: (json['emiSummaries'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        extractedVia: json['extractedVia'] as String?,
      );
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
