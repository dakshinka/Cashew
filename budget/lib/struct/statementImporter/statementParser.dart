import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:excel/excel.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
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

  /// Parse CSV / TSV string into StatementEntry list and enrich with AI categorization
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
    return parseRows(rows,
        customIndices: customIndices, targetWalletPk: targetWalletPk);
  }

  /// Parses binary Excel (.xlsx / .xls) spreadsheet bytes
  static Future<List<StatementEntry>> parseExcelBytes(
    List<int> bytes, {
    StatementColumnIndices? customIndices,
    String? targetWalletPk,
  }) async {
    try {
      final excel = Excel.decodeBytes(bytes);
      List<List<dynamic>> rows = [];
      for (final table in excel.tables.keys) {
        final sheet = excel.tables[table];
        if (sheet != null && sheet.rows.isNotEmpty) {
          for (final row in sheet.rows) {
            rows.add(
                row.map((cell) => cell?.value?.toString() ?? "").toList());
          }
          if (rows.length > 2) break; // Pick first populated sheet
        }
      }
      if (rows.isNotEmpty) {
        return await parseRows(rows,
            customIndices: customIndices, targetWalletPk: targetWalletPk);
      }
    } catch (e) {
      debugPrint("Error parsing Excel bytes: $e");
    }
    return [];
  }

  /// Parses digital PDF statement bytes (bank and credit card statements)
  static Future<List<StatementEntry>> parsePdfBytes(
    List<int> bytes, {
    StatementColumnIndices? customIndices,
    String? targetWalletPk,
  }) async {
    try {
      final document = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(document);
      final fullText = extractor.extractText();
      document.dispose();

      if (fullText.trim().isEmpty) return [];

      // 1. Try deterministic multi-line statement text parser
      final entries = await parsePdfTextLines(fullText,
          targetWalletPk: targetWalletPk);
      if (entries.isNotEmpty) {
        return entries;
      }

      // 2. If line layout is multi-column or transactions span pages 2/3 (e.g. credit card statements),
      // invoke AI extraction helper
      final aiEntries = await parseStatementWithAi(fullText,
          targetWalletPk: targetWalletPk);
      if (aiEntries.isNotEmpty) {
        return aiEntries;
      }
    } catch (e) {
      debugPrint("Error parsing PDF statement: $e");
    }
    return [];
  }

  /// Deterministic line parser for structured bank & credit card statement text
  static Future<List<StatementEntry>> parsePdfTextLines(
    String fullText, {
    String? targetWalletPk,
  }) async {
    final lines = fullText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final List<StatementEntry> entries = [];

    // Line matching pattern for common bank/credit card statement rows:
    // e.g. "04/11/2026 SWIGGY BANGALORE 450.00" or "04-Nov-2026 STARBUCKS 320.00 Cr"
    final lineRegex = RegExp(
      r'^\s*([0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4}|[0-3]?[0-9]\s+[A-Za-z]{3}\s+[0-9]{2,4})\s+(.+?)\s+([0-9]{1,3}(?:[,\s][0-9]{2,3})*(?:\.[0-9]{1,2})?)\s*(Cr|Dr|Credit|Debit)?\s*$',
      caseSensitive: false,
    );

    for (final line in lines) {
      final m = lineRegex.firstMatch(line);
      if (m != null) {
        final dateStr = m.group(1)!;
        final narr = m.group(2)!.trim();
        final amtStr = m.group(3)!;
        final typeIndicator = m.group(4)?.toLowerCase();

        final date = parseFlexibleDate(dateStr);
        final amt = parseAmount(amtStr);
        if (date == null || amt <= 0) continue;

        // Skip non-transaction summary headers
        final lowerNarr = narr.toLowerCase();
        if (lowerNarr.contains("balance") ||
            lowerNarr.contains("opening") ||
            lowerNarr.contains("closing") ||
            lowerNarr.contains("credit limit") ||
            lowerNarr.contains("total amount due")) {
          continue;
        }

        final isIncome = typeIndicator == "cr" || typeIndicator == "credit";
        final cleanMerchant = AiCategorizer.cleanMerchantName(narr);
        final aiSuggestion = await AiCategorizer.suggestCategory(cleanMerchant,
            isIncome: isIncome);

        entries.add(
          StatementEntry(
            date: date,
            rawNarration: narr,
            cleanMerchant: cleanMerchant,
            amount: amt,
            isIncome: isIncome,
            suggestedCategoryName: aiSuggestion.categoryName,
            suggestedCategoryPk: aiSuggestion.categoryPk,
            confidence: aiSuggestion.confidence,
          ),
        );
      }
    }

    if (targetWalletPk != null && targetWalletPk.isNotEmpty) {
      await checkDuplicates(entries, targetWalletPk);
    }
    return entries;
  }

  /// AI-assisted statement extractor for complex, multi-column, or multi-page credit card statements
  static Future<List<StatementEntry>> parseStatementWithAi(
    String fullText, {
    String? targetWalletPk,
  }) async {
    try {
      final lines = fullText.split('\n');
      final transactionLines = lines.where((l) {
        final lower = l.toLowerCase();
        return RegExp(
                    r'[0-9]{1,2}[/-][0-9]{1,2}[/-][0-9]{2,4}|[0-9]{1,2}\s+[A-Za-z]{3}')
                .hasMatch(l) &&
            RegExp(r'[0-9]+(?:\.[0-9]{2})?').hasMatch(l) &&
            !lower.contains("statement summary") &&
            !lower.contains("credit limit") &&
            !lower.contains("payment due");
      }).take(100).join('\n');

      final sample = transactionLines.isNotEmpty
          ? transactionLines
          : lines.take(150).join('\n');

      final prompt = '''
You are an expert credit card and bank statement extraction engine.
Extract all actual individual transactions (purchases, payments, transfers) from this statement text into a JSON array.
Skip header information, summary balances, reward points, and credit limits.

Statement text:
"""
$sample
"""

Respond ONLY with valid JSON array:
[
  {
    "date": "YYYY-MM-DD",
    "description": "merchant or payee",
    "amount": 250.0,
    "isIncome": false
  }
]
''';

      final resText = await LlmClassifier.queryActiveLlm(prompt);
      if (resText != null && resText.isNotEmpty) {
        final cleanJson =
            resText.replaceAll(RegExp(r'```json|```'), '').trim();
        final dynamic decoded = jsonDecode(cleanJson);
        if (decoded is List) {
          final List<StatementEntry> entries = [];
          for (final item in decoded) {
            if (item is! Map) continue;
            final dateStr = item["date"]?.toString() ?? "";
            final date = DateTime.tryParse(dateStr) ??
                parseFlexibleDate(dateStr) ??
                DateTime.now();
            final desc = item["description"]?.toString() ?? "Transaction";
            final amt = (item["amount"] is num)
                ? (item["amount"] as num).toDouble().abs()
                : parseAmount(item["amount"]?.toString() ?? "0");
            final isIncome = item["isIncome"] == true;
            if (amt <= 0) continue;

            final cleanMerchant = AiCategorizer.cleanMerchantName(desc);
            final aiSuggestion = await AiCategorizer.suggestCategory(
                cleanMerchant,
                isIncome: isIncome);

            entries.add(
              StatementEntry(
                date: date,
                rawNarration: desc,
                cleanMerchant: cleanMerchant,
                amount: amt,
                isIncome: isIncome,
                suggestedCategoryName: aiSuggestion.categoryName,
                suggestedCategoryPk: aiSuggestion.categoryPk,
                confidence: aiSuggestion.confidence,
              ),
            );
          }

          if (targetWalletPk != null && targetWalletPk.isNotEmpty) {
            await checkDuplicates(entries, targetWalletPk);
          }
          return entries;
        }
      }
    } catch (e) {
      debugPrint("AI statement extraction error: $e");
    }
    return [];
  }

  /// Determines whether a bank transaction narration represents an ATM or cash withdrawal
  static bool isCashWithdrawalNarration(String narration) {
    final lower = narration.toLowerCase();
    final regex = RegExp(
      r'\b(atm|cash\s*(?:wdl|withdrawal|dispense|w\/d)|nfs\*atm|cwdr|matm|self\s*wdl|euronet|atm-cash|cash-wdl|pos\s*cash)\b',
      caseSensitive: false,
    );
    return regex.hasMatch(lower);
  }

  /// Shared engine that maps tabular rows into StatementEntry items
  static Future<List<StatementEntry>> parseRows(
    List<List<dynamic>> rows, {
    StatementColumnIndices? customIndices,
    String? targetWalletPk,
  }) async {
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

      final rawNarr =
          indices.narrationCol >= 0 && indices.narrationCol < row.length
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

      // Check for Cash / ATM withdrawal
      final isCash = isCashWithdrawalNarration(rawNarr);
      final cleanMerchant = isCash
          ? "ATM Cash Withdrawal"
          : AiCategorizer.cleanMerchantName(rawNarr);
      final aiSuggestion = await AiCategorizer.suggestCategory(cleanMerchant,
          isIncome: isIncome);

      entries.add(
        StatementEntry(
          date: date,
          rawNarration: rawNarr,
          cleanMerchant: cleanMerchant,
          amount: amount,
          isIncome: isIncome,
          referenceNo: refNo,
          balance: bal,
          suggestedCategoryName:
              isCash ? "Cash & ATM" : aiSuggestion.categoryName,
          suggestedCategoryPk: aiSuggestion.categoryPk,
          confidence: isCash ? 0.99 : aiSuggestion.confidence,
          isCashWithdrawal: isCash,
          isTransferToCash: isCash,
        ),
      );
    }

    // Reconcile against both database transactions and Review Inbox
    if (targetWalletPk != null && targetWalletPk.isNotEmpty) {
      await checkDuplicates(entries, targetWalletPk);
    }

    return entries;
  }

  /// Checks existing transactions in wallet and Review Inbox to reconcile and flag duplicates
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

    // 1. Reconcile against persisted transactions in SQLite database
    final walletTransactions =
        await database.getAllTransactionsFromWallet(walletPk);
    final existing = walletTransactions
        .where((t) =>
            t.dateCreated.isAfter(searchStart) &&
            t.dateCreated.isBefore(searchEnd))
        .toList();

    // 2. Reconcile against pending SMS in Review Inbox
    final pendingSms = ReviewManager.instance.pendingTransactions;

    for (final entry in entries) {
      // Check SQLite DB
      bool matched = false;
      for (final tx in existing) {
        final diffDays = entry.date.difference(tx.dateCreated).inDays.abs();
        final amountMatches = (tx.amount.abs() - entry.amount).abs() < 0.01;
        final typeMatches = (tx.income == entry.isIncome);

        if (diffDays <= 1 && amountMatches && typeMatches) {
          entry.duplicateState = DuplicateState.confirmedDuplicate;
          entry.matchedSource = 'database';
          entry.isSelected = false; // Deselect already-reconciled items
          entry.duplicateReason =
              "Reconciled with existing '${tx.name}' (${DateFormat('dd MMM').format(tx.dateCreated)})";
          matched = true;
          break;
        }
      }

      if (!matched) {
        // Check Review Inbox pending SMS
        for (final item in pendingSms) {
          final diffDays = entry.date.difference(item.date).inDays.abs();
          final amountMatches = (item.amount.abs() - entry.amount).abs() < 0.01;
          final typeMatches = (item.isIncome == entry.isIncome);

          if (diffDays <= 1 && amountMatches && typeMatches) {
            entry.duplicateState = DuplicateState.potentialDuplicate;
            entry.matchedSource = 'review_inbox';
            entry.isSelected = false;
            entry.duplicateReason =
                "Matches pending SMS in Review Inbox: '${item.cleanMerchant}' (${DateFormat('dd MMM').format(item.date)})";
            matched = true;
            break;
          }
        }
      }

      if (!matched) {
        entry.duplicateState = DuplicateState.unique;
        entry.matchedSource = null;
        entry.isSelected = true; // Selected by default to import missing transactions!
        entry.duplicateReason = "Missing from account (No SMS or record found)";
      }
    }
  }
}
