import 'dart:convert';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Represents a period during which a specific unit price was in effect.
/// e.g. from Nov 1 to Nov 17, milk was ₹35/L.
/// From Nov 18 onwards (endDate == null), milk is ₹37/L.
class RateSchedulePeriod {
  final String periodId;
  final DateTime startDate;
  final DateTime? endDate;
  final double unitPrice;
  final String unitName;

  RateSchedulePeriod({
    String? periodId,
    required this.startDate,
    this.endDate,
    required this.unitPrice,
    this.unitName = "L",
  }) : periodId = periodId ?? _uuid.v4();

  bool appliesTo(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final s = DateTime(startDate.year, startDate.month, startDate.day);
    if (d.isBefore(s)) return false;
    if (endDate != null) {
      final e = DateTime(endDate!.year, endDate!.month, endDate!.day);
      if (d.isAfter(e)) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'periodId': periodId,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'unitPrice': unitPrice,
        'unitName': unitName,
      };

  factory RateSchedulePeriod.fromJson(Map<String, dynamic> json) =>
      RateSchedulePeriod(
        periodId: json['periodId'] as String?,
        startDate: DateTime.parse(json['startDate'] as String),
        endDate: json['endDate'] != null
            ? DateTime.parse(json['endDate'] as String)
            : null,
        unitPrice: (json['unitPrice'] as num).toDouble(),
        unitName: (json['unitName'] as String?) ?? "L",
      );
}

/// Represents the daily delivery calculation for a single calendar day.
class DailyDeliveryDayDetail {
  final DateTime date;
  final double quantity;
  final double unitPrice;
  final double cost;
  final bool isSkipped;
  final bool isExtra;
  final String? note;

  DailyDeliveryDayDetail({
    required this.date,
    required this.quantity,
    required this.unitPrice,
    required this.cost,
    required this.isSkipped,
    required this.isExtra,
    this.note,
  });
}

/// Detailed calculation summary for an entire calendar month.
class MonthlyDeliverySummary {
  final int year;
  final int month;
  final int totalDaysInMonth;
  final int normalDaysCount;
  final int skippedDaysCount;
  final int extraDaysCount;
  final double totalUnits;
  final double totalCost;
  final List<DailyDeliveryDayDetail> dailyDetails;

  MonthlyDeliverySummary({
    required this.year,
    required this.month,
    required this.totalDaysInMonth,
    required this.normalDaysCount,
    required this.skippedDaysCount,
    required this.extraDaysCount,
    required this.totalUnits,
    required this.totalCost,
    required this.dailyDetails,
  });
}

/// Represents a Daily Recurring Service (e.g. Milk, Newspaper, Water Cans, Tiffin)
/// linked to a Vendor Tab (Khata).
class DailyDeliveryService {
  final String servicePk;
  String name;
  String vendorTabWalletPk;
  String? categoryPk;
  double defaultDailyQuantity;
  String unitName;
  List<RateSchedulePeriod> ratePeriods;
  // Key format: "YYYY-MM-DD" -> custom quantity for that day (e.g. 0.0 for skip, 2.0 for extra)
  Map<String, double> dailyOverrides;
  DateTime dateCreated;
  DateTime dateTimeModified;

  DailyDeliveryService({
    String? servicePk,
    required this.name,
    required this.vendorTabWalletPk,
    this.categoryPk,
    this.defaultDailyQuantity = 1.0,
    this.unitName = "L",
    List<RateSchedulePeriod>? ratePeriods,
    Map<String, double>? dailyOverrides,
    DateTime? dateCreated,
    DateTime? dateTimeModified,
  })  : servicePk = servicePk ?? _uuid.v4(),
        ratePeriods = ratePeriods ?? [],
        dailyOverrides = dailyOverrides ?? {},
        dateCreated = dateCreated ?? DateTime.now(),
        dateTimeModified = dateTimeModified ?? DateTime.now();

  /// Gets the effective unit price for a specific date
  double getPriceForDate(DateTime date) {
    for (final period in ratePeriods) {
      if (period.appliesTo(date)) {
        return period.unitPrice;
      }
    }
    // Fallback: use the latest period price or 0.0
    if (ratePeriods.isNotEmpty) {
      return ratePeriods.last.unitPrice;
    }
    return 0.0;
  }

  /// Gets quantity delivered for a specific date (considers skips & extras)
  double getQuantityForDate(DateTime date) {
    final key = _formatDateKey(date);
    if (dailyOverrides.containsKey(key)) {
      return dailyOverrides[key]!;
    }
    return defaultDailyQuantity;
  }

  /// Sets an override for a date (0.0 to skip, 2.0 for extra, or null to revert to default)
  void setOverrideForDate(DateTime date, double? quantity) {
    final key = _formatDateKey(date);
    if (quantity == null || quantity == defaultDailyQuantity) {
      dailyOverrides.remove(key);
    } else {
      dailyOverrides[key] = quantity;
    }
    dateTimeModified = DateTime.now();
  }

  /// Calculates the complete statement for any month
  MonthlyDeliverySummary calculateMonth(int year, int month) {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final List<DailyDeliveryDayDetail> details = [];

    int normalDays = 0;
    int skippedDays = 0;
    int extraDays = 0;
    double totalUnits = 0.0;
    double totalCost = 0.0;

    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(year, month, day);
      final qty = getQuantityForDate(date);
      final unitPrice = getPriceForDate(date);
      final cost = qty * unitPrice;

      final isSkipped = qty == 0.0;
      final isExtra = qty > defaultDailyQuantity;

      if (isSkipped) {
        skippedDays++;
      } else if (isExtra) {
        extraDays++;
      } else {
        normalDays++;
      }

      totalUnits += qty;
      totalCost += cost;

      details.add(DailyDeliveryDayDetail(
        date: date,
        quantity: qty,
        unitPrice: unitPrice,
        cost: cost,
        isSkipped: isSkipped,
        isExtra: isExtra,
      ));
    }

    return MonthlyDeliverySummary(
      year: year,
      month: month,
      totalDaysInMonth: daysInMonth,
      normalDaysCount: normalDays,
      skippedDaysCount: skippedDays,
      extraDaysCount: extraDays,
      totalUnits: totalUnits,
      totalCost: totalCost,
      dailyDetails: details,
    );
  }

  static String _formatDateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return "$y-$m-$day";
  }

  Map<String, dynamic> toJson() => {
        'servicePk': servicePk,
        'name': name,
        'vendorTabWalletPk': vendorTabWalletPk,
        'categoryPk': categoryPk,
        'defaultDailyQuantity': defaultDailyQuantity,
        'unitName': unitName,
        'ratePeriods': ratePeriods.map((e) => e.toJson()).toList(),
        'dailyOverrides': dailyOverrides,
        'dateCreated': dateCreated.toIso8601String(),
        'dateTimeModified': dateTimeModified.toIso8601String(),
      };

  factory DailyDeliveryService.fromJson(Map<String, dynamic> json) =>
      DailyDeliveryService(
        servicePk: json['servicePk'] as String?,
        name: json['name'] as String,
        vendorTabWalletPk: json['vendorTabWalletPk'] as String,
        categoryPk: json['categoryPk'] as String?,
        defaultDailyQuantity:
            (json['defaultDailyQuantity'] as num?)?.toDouble() ?? 1.0,
        unitName: (json['unitName'] as String?) ?? "L",
        ratePeriods: (json['ratePeriods'] as List? ?? [])
            .map((e) => RateSchedulePeriod.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        dailyOverrides: (json['dailyOverrides'] as Map? ?? {})
            .map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
        dateCreated: json['dateCreated'] != null
            ? DateTime.parse(json['dateCreated'] as String)
            : null,
        dateTimeModified: json['dateTimeModified'] != null
            ? DateTime.parse(json['dateTimeModified'] as String)
            : null,
      );
}
