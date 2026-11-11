import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';
import 'package:budget/struct/statementImporter/statementModels.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

class StatementParser {
  static final List<String> _dateHeaders = [
    "date",
    "txn date",
    "value date",
    "transaction date",
    "posting date",
    "trans date",
  ];

  static final List<String> _narrationHeaders = [
    "narration",
    "description",
    "particulars",
    "remarks",
    "details",
    "transaction details",
    "payee",
    "merchant",
  ];

  static final List<String> _debitHeaders = [
    "debit",
    "dr",
    "withdrawal",
    "debit amount",
    "dr amount",
    "withdrawal amount",
    "spent",
  ];

  static final List<String> _creditHeaders = [
    "credit",
    "cr",
    "deposit",
    "credit amount",
    "cr amount",
    "deposit amount",
    "received",
  ];

  static final List<String> _amountHeaders = [
    "amount",
    "txn amount",
    "net amount",
    "transaction amount",
  ];

  static final List<String> _refHeaders = [
    "chq",
    "ref",
    "cheque",
    "reference",
    "utr",
    "chq/ref no",
    "ref no",
  ];

  static final List<String> _balanceHeaders = [
    "balance",
    "closing balance",
    "bal",
    "available balance",
  ];

  /// Detect columns automatically from parsed rows
  static StatementColumnIndices detectColumns(List<List<dynamic>> rows) {
    final indices = StatementColumnIndices();
    if (rows.isEmpty) return indices;

    // Scan the first 50 rows to find the actual table header row (accommodates bank metadata, branch, and customer details)
    for (int r = 0; r < rows.length && r < 50; r++) {
      final row = rows[r].map((e) => e.toString().trim().toLowerCase()).toList();

      int matchCount = 0;
      int dateIdx = -1;
      int narrIdx = -1;
      int? debIdx;
      int? credIdx;
      int? amtIdx;
      int? refIdx;
      int? balIdx;

      for (int c = 0; c < row.length; c++) {
        final colName = row[c];
        if (colName.isEmpty) continue;

        if (_dateHeaders.any((h) => colName.contains(h)) && dateIdx == -1) {
          dateIdx = c;
          matchCount++;
        } else if (_narrationHeaders.any((h) => colName.contains(h)) &&
            narrIdx == -1) {
          narrIdx = c;
          matchCount++;
        } else if (_debitHeaders.any((h) => colName == h || colName.startsWith(h))) {
          debIdx = c;
          matchCount++;
        } else if (_creditHeaders.any((h) => colName == h || colName.startsWith(h))) {
          credIdx = c;
          matchCount++;
        } else if (_amountHeaders.any((h) => colName == h || colName.startsWith(h)) &&
            amtIdx == null) {
          amtIdx = c;
          matchCount++;
        } else if (_refHeaders.any((h) => colName.contains(h)) &&
            refIdx == null) {
          refIdx = c;
        } else if (_balanceHeaders.any((h) => colName.contains(h)) &&
            balIdx == null) {
          balIdx = c;
        }
      }

      // If at least date and narration or amount matched, consider this the header row
      if (matchCount >= 2 && (dateIdx != -1 || narrIdx != -1)) {
        indices.headerRowIndex = r;
        indices.dateCol = dateIdx;
        indices.narrationCol = narrIdx;
        indices.debitCol = debIdx;
        indices.creditCol = credIdx;
        indices.amountCol = amtIdx;
        indices.refCol = refIdx;
        indices.balanceCol = balIdx;
        return indices;
      }
    }

    return indices;
  }

  /// Parses date string with various common formats
  static DateTime? parseFlexibleDate(String rawDate) {
    final clean = rawDate.trim();
    if (clean.isEmpty) return null;

    final formats = [
      "dd/MM/yyyy",
      "dd-MM-yyyy",
      "yyyy-MM-dd",
      "dd/MM/yy",
      "dd-MM-yy",
      "MM/dd/yyyy",
      "d/M/yyyy",
      "d-M-yyyy",
      "dd-MMM-yyyy",
      "dd MMM yyyy",
      "dd/MMM/yyyy",
      "yyyy/MM/dd",
    ];

    for (final fmt in formats) {
      try {
        return DateFormat(fmt, 'en_US').parseLoose(clean);
      } catch (_) {}
    }

    return DateTime.tryParse(clean);
  }

  /// Cleans amount string (e.g. "₹ 1,234.50", "(500.00)", "CR 1,000")
  static double parseAmount(String raw) {
    if (raw.trim().isEmpty) return 0.0;
    var clean = raw.replaceAll(RegExp(r'[^\d.,\-]'), '').trim();
    if (clean.isEmpty) return 0.0;

    // Handle trailing minus (e.g. 500.00-)
    bool isNeg = false;
    if (clean.endsWith('-') || raw.contains('(') && raw.contains(')')) {
      isNeg = true;
      clean = clean.replaceAll('-', '');
    }

    // Replace thousands comma
    clean = clean.replaceAll(',', '');
    final val = double.tryParse(clean) ?? 0.0;
    return isNeg ? -val.abs() : val;
  }

  /// Parse CSV string into StatementEntry list and enrich with AI categorization
  static Future<List<StatementEntry>> parseCsv(
    String csvContent, {
    StatementColumnIndices? customIndices,
    String? targetWalletPk,
  }) async {
    // Normalize Windows CRLF
    final normalized =
        csvContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Auto-detect delimiter: comma, tab (copied from Excel/Sheets), or semicolon
    String delimiter = ',';
    final sampleLines = normalized.split('\n').take(15).join('\n');
    final commaCount = ','.allMatches(sampleLines).length;
    final tabCount = '\t'.allMatches(sampleLines).length;
    final semiCount = ';'.allMatches(sampleLines).length;

    if (tabCount > commaCount && tabCount > semiCount) {
      delimiter = '\t';
    } else if (semiCount > commaCount && semiCount > tabCount) {
      delimiter = ';';
    }

    final converter = CsvToListConverter(
      fieldDelimiter: delimiter,
      shouldParseNumbers: false,
      eol: '\n',
    );

    final rows = converter.convert(normalized);

    if (rows.isEmpty) return [];

    final indices = customIndices ?? detectColumns(rows);
    if (!indices.isValid) return [];

    final List<StatementEntry> entries = [];
    final startRow = indices.headerRowIndex + 1;

    for (int r = startRow; r < rows.length; r++) {
      final row = rows[r];
      if (row.isEmpty || row.length <= indices.dateCol) continue;

      final rawDate = row[indices.dateCol].toString().trim();
      final date = parseFlexibleDate(rawDate);
      if (date == null) continue; // Skip footer / summary rows

      final rawNarr = indices.narrationCol >= 0 && indices.narrationCol < row.length
          ? row[indices.narrationCol].toString().trim()
          : "Transaction";

      if (rawNarr.isEmpty) continue;

      double amount = 0.0;
      bool isIncome = false;

      if (indices.debitCol != null &&
          indices.debitCol! < row.length &&
          row[indices.debitCol!].toString().trim().isNotEmpty) {
        final deb = parseAmount(row[indices.debitCol!].toString());
        if (deb > 0) {
          amount = deb;
          isIncome = false;
        }
      }

      if (indices.creditCol != null &&
          indices.creditCol! < row.length &&
          row[indices.creditCol!].toString().trim().isNotEmpty) {
        final cred = parseAmount(row[indices.creditCol!].toString());
        if (cred > 0) {
          amount = cred;
          isIncome = true;
        }
      }

      // If single amount column
      if (amount == 0.0 &&
          indices.amountCol != null &&
          indices.amountCol! < row.length) {
        final val = parseAmount(row[indices.amountCol!].toString());
        amount = val.abs();
        isIncome = val > 0;
      }

      if (amount <= 0.0) continue;

      String? refNo;
      if (indices.refCol != null && indices.refCol! < row.length) {
        refNo = row[indices.refCol!].toString().trim();
      }

      double? bal;
      if (indices.balanceCol != null && indices.balanceCol! < row.length) {
        bal = parseAmount(row[indices.balanceCol!].toString());
      }

      // AI Cleans the merchant and assigns category
      final cleanMerchant = AiCategorizer.cleanMerchantName(rawNarr);
      final aiSuggestion = await AiCategorizer.suggestCategory(cleanMerchant);

      entries.add(
        StatementEntry(
          date: date,
          rawNarration: rawNarr,
          cleanMerchant: cleanMerchant,
          amount: amount,
          isIncome: isIncome,
          referenceNo: refNo,
          balance: bal,
          suggestedCategoryName: aiSuggestion.categoryName,
          suggestedCategoryPk: aiSuggestion.categoryPk,
          confidence: aiSuggestion.confidence,
        ),
      );
    }

    // Duplicate detection against Drift DB
    if (targetWalletPk != null && targetWalletPk.isNotEmpty) {
      await checkDuplicates(entries, targetWalletPk);
    }

    return entries;
  }

  /// Checks existing transactions in wallet around statement dates to flag duplicates
  static Future<void> checkDuplicates(
    List<StatementEntry> entries,
    String walletPk,
  ) async {
    if (entries.isEmpty) return;

    DateTime minDate = entries.first.date;
    DateTime maxDate = entries.first.date;
    for (final e in entries) {
      if (e.date.isBefore(minDate)) minDate = e.date;
      if (e.date.isAfter(maxDate)) maxDate = e.date;
    }

    // Expand search window by 2 days
    final searchStart = minDate.subtract(const Duration(days: 2));
    final searchEnd = maxDate.add(const Duration(days: 2));

    final walletTransactions =
        await database.getAllTransactionsFromWallet(walletPk);
    final existing = walletTransactions
        .where((t) =>
            t.dateCreated.isAfter(searchStart) &&
            t.dateCreated.isBefore(searchEnd))
        .toList();

    for (final entry in entries) {
      for (final tx in existing) {
        final diffDays = entry.date.difference(tx.dateCreated).inDays.abs();
        final amountMatches = (tx.amount.abs() - entry.amount).abs() < 0.01;
        final typeMatches = (tx.income == entry.isIncome);

        if (diffDays <= 1 && amountMatches && typeMatches) {
          entry.duplicateState = DuplicateState.potentialDuplicate;
          entry.isSelected = false; // Deselect by default to prevent accidental double-count
          entry.duplicateReason =
              "Matches existing '${tx.name}' on ${DateFormat('dd MMM').format(tx.dateCreated)}";
          break;
        }
      }
    }
  }
}
