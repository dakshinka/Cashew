import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum ReviewStatus {
  pending,
  approved,
  dismissed,
  ignored, // Captured as non-transaction / informational / other SMS with numbers
}

class ReviewTransaction {
  final String id;
  final String rawMessage;
  final String extractedTitle;
  String cleanMerchant;
  double amount;
  String currency;
  DateTime date;
  bool isIncome;
  String suggestedCategoryName;
  String? suggestedCategoryPk;
  String? suggestedSubCategoryName;
  String? suggestedSubCategoryPk;
  double confidence;
  String? accountHint;
  String? suggestedWalletPk;
  ReviewStatus status;
  final bool isReminder;
  final String? ignoredReason;
  final DateTime timestamp;

  String get displayCurrency {
    if (currency == "INR" || currency == "Rs." || currency == "Rs") return "₹";
    return currency;
  }

  ReviewTransaction({
    String? id,
    required this.rawMessage,
    required this.extractedTitle,
    required this.cleanMerchant,
    required this.amount,
    this.currency = "₹",
    required this.date,
    required this.isIncome,
    required this.suggestedCategoryName,
    this.suggestedCategoryPk,
    this.suggestedSubCategoryName,
    this.suggestedSubCategoryPk,
    this.confidence = 0.85,
    this.accountHint,
    this.suggestedWalletPk,
    this.status = ReviewStatus.pending,
    this.isReminder = false,
    this.ignoredReason,
    DateTime? timestamp,
  })  : id = id ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'rawMessage': rawMessage,
        'extractedTitle': extractedTitle,
        'cleanMerchant': cleanMerchant,
        'amount': amount,
        'currency': currency,
        'date': date.toIso8601String(),
        'isIncome': isIncome,
        'suggestedCategoryName': suggestedCategoryName,
        'suggestedCategoryPk': suggestedCategoryPk,
        'suggestedSubCategoryName': suggestedSubCategoryName,
        'suggestedSubCategoryPk': suggestedSubCategoryPk,
        'confidence': confidence,
        'accountHint': accountHint,
        'suggestedWalletPk': suggestedWalletPk,
        'status': status.index,
        'isReminder': isReminder,
        'ignoredReason': ignoredReason,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ReviewTransaction.fromJson(Map<String, dynamic> json) =>
      ReviewTransaction(
        id: json['id'] as String?,
        rawMessage: json['rawMessage'] as String? ?? "",
        extractedTitle: json['extractedTitle'] as String? ?? "",
        cleanMerchant: json['cleanMerchant'] as String? ?? "",
        amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
        currency: json['currency'] as String? ?? "₹",
        date: json['date'] != null
            ? DateTime.parse(json['date'] as String)
            : DateTime.now(),
        isIncome: json['isIncome'] as bool? ?? false,
        suggestedCategoryName:
            json['suggestedCategoryName'] as String? ?? "Other",
        suggestedCategoryPk: json['suggestedCategoryPk'] as String?,
        suggestedSubCategoryName: json['suggestedSubCategoryName'] as String?,
        suggestedSubCategoryPk: json['suggestedSubCategoryPk'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
        accountHint: json['accountHint'] as String?,
        suggestedWalletPk: json['suggestedWalletPk'] as String?,
        status: ReviewStatus
            .values[(json['status'] as int?) ?? ReviewStatus.pending.index],
        isReminder: json['isReminder'] as bool? ?? false,
        ignoredReason: json['ignoredReason'] as String?,
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'] as String)
            : DateTime.now(),
      );
}
