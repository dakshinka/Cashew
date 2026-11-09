import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class ReceiptItem {
  final String id;
  String? transactionPk;
  String title;
  String storeName;
  DateTime purchaseDate;
  double price;
  DateTime? warrantyExpiryDate;
  String? notes;
  String? imagePath;

  ReceiptItem({
    String? id,
    this.transactionPk,
    required this.title,
    required this.storeName,
    required this.purchaseDate,
    required this.price,
    this.warrantyExpiryDate,
    this.notes,
    this.imagePath,
  }) : id = id ?? _uuid.v4();

  bool get hasWarranty => warrantyExpiryDate != null;

  bool get isWarrantyExpired =>
      hasWarranty && warrantyExpiryDate!.isBefore(DateTime.now());

  int get warrantyDaysRemaining {
    if (!hasWarranty) return 0;
    return warrantyExpiryDate!.difference(DateTime.now()).inDays;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'transactionPk': transactionPk,
        'title': title,
        'storeName': storeName,
        'purchaseDate': purchaseDate.toIso8601String(),
        'price': price,
        'warrantyExpiryDate': warrantyExpiryDate?.toIso8601String(),
        'notes': notes,
        'imagePath': imagePath,
      };

  factory ReceiptItem.fromJson(Map<String, dynamic> json) => ReceiptItem(
        id: json['id'] as String?,
        transactionPk: json['transactionPk'] as String?,
        title: json['title'] as String? ?? "Receipt",
        storeName: json['storeName'] as String? ?? "Store",
        purchaseDate: json['purchaseDate'] != null
            ? DateTime.parse(json['purchaseDate'] as String)
            : DateTime.now(),
        price: (json['price'] as num?)?.toDouble() ?? 0.0,
        warrantyExpiryDate: json['warrantyExpiryDate'] != null
            ? DateTime.parse(json['warrantyExpiryDate'] as String)
            : null,
        notes: json['notes'] as String?,
        imagePath: json['imagePath'] as String?,
      );
}
