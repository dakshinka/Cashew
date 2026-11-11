import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:excel/excel.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:universal_html/parsing.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
import 'package:budget/struct/smsReview/smsParser.dart';
import 'package:budget/struct/statementImporter/statementModels.dart';
import 'package:budget/struct/statementImporter/biff8Parser.dart';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

class PdfPasswordException implements Exception {
  final String message;
  final bool isIncorrect;

  PdfPasswordException(this.message, {this.isIncorrect = false});

  @override
  String toString() => message;
}

class StatementParser {
  static CreditCardStatementSummary? lastExtractedSummary;

  /// Extracts credit card statement metadata (Statement date, due date, total due, interest charges, EMIs)
  static CreditCardStatementSummary extractCreditCardSummary(String fullText) {
    DateTime? statementDate;
    final stmtDateMatch = RegExp(
      r'(?:statement|billing)\s*date\s*[:\-]?\s*([0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4}|[0-3]?[0-9]\s+[A-Za-z]{3}\s+[0-9]{2,4}|[0-3]?[0-9]-[A-Za-z]{3}-[0-9]{2,4})',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (stmtDateMatch != null) {
      statementDate = parseFlexibleDate(stmtDateMatch.group(1)!);
    }

    DateTime? dueDate;
    final dueDateMatch = RegExp(
      r'(?:payment\s*due\s*date|due\s*date)\s*[:\-]?\s*([0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4}|[0-3]?[0-9]\s+[A-Za-z]{3}\s+[0-9]{2,4}|[0-3]?[0-9]-[A-Za-z]{3}-[0-9]{2,4})',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (dueDateMatch != null) {
      dueDate = parseFlexibleDate(dueDateMatch.group(1)!);
    }

    double? totalDue;
    final totalDueMatch = RegExp(
      r'total\s*amount\s*due\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{2})?)',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (totalDueMatch != null) {
      totalDue = parseAmount(totalDueMatch.group(1)!);
    }

    double? minDue;
    final minDueMatch = RegExp(
      r'(?:minimum|min\.?)\s*amount\s*due\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{2})?)',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (minDueMatch != null) {
      minDue = parseAmount(minDueMatch.group(1)!);
    }

    double? limit;
    final limitMatch = RegExp(
      r'(?:total\s*)?credit\s*limit\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{2})?)',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (limitMatch != null) {
      limit = parseAmount(limitMatch.group(1)!);
    }

    double? avlLimit;
    final avlMatch = RegExp(
      r'available\s*(?:credit|limit)\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{2})?)',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (avlMatch != null) {
      avlLimit = parseAmount(avlMatch.group(1)!);
    }

    double? financeCharges;
    final financeMatch = RegExp(
      r'(?:finance|interest)\s*charges?\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{2})?)',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (financeMatch != null) {
      financeCharges = parseAmount(financeMatch.group(1)!);
    }

    double? gstCharges;
    final gstMatch = RegExp(
      r'(?:total\s*taxes|igst|gst\s*on\s*charges)\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{2})?)',
      caseSensitive: false,
    ).firstMatch(fullText);
    if (gstMatch != null) {
      gstCharges = parseAmount(gstMatch.group(1)!);
    }

    final List<String> emis = [];
    final lines = fullText.split('\n');
    for (final l in lines) {
      final upper = l.toUpperCase();
      if ((upper.contains('EMI') || upper.contains('LOAN ON CARD')) &&
          RegExp(r'[0-9]+(?:\.[0-9]{2})?').hasMatch(l)) {
        final clean = l.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (clean.length > 5 && !emis.contains(clean)) {
          emis.add(clean);
        }
      }
    }

    final summary = CreditCardStatementSummary(
      statementDate: statementDate,
      dueDate: dueDate,
      totalAmountDue: totalDue,
      minAmountDue: minDue,
      creditLimit: limit,
      availableCredit: avlLimit,
      financeCharges: financeCharges,
      gstCharges: gstCharges,
      emiSummaries: emis,
    );

    lastExtractedSummary = summary;
    return summary;
  }

  /// Detect columns automatically from parsed rows
  static StatementColumnIndices detectColumns(List<List<dynamic>> rows) {
    final indices = StatementColumnIndices();
    if (rows.isEmpty) return indices;

    // 1. Scan up to 60 rows to find the actual table header row using regex matching
    for (int r = 0; r < rows.length && r < 60; r++) {
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

        final isDate = RegExp(
                r'\b(date|dt|txn\s*date|trans\s*date|value\s*date|posting\s*date|post\s*date|book\s*date)\b',
                caseSensitive: false)
            .hasMatch(colName);
        final isNarration = RegExp(
                r'\b(narration|particulars|description|remarks|details|payee|merchant|desc)\b',
                caseSensitive: false)
            .hasMatch(colName);
        final isDebit = RegExp(
                r'\b(debit|dr|withdrawal|withdrawals|spent|paid\s*out|money\s*out)\b',
                caseSensitive: false)
            .hasMatch(colName);
        final isCredit = RegExp(
                r'\b(credit|cr|deposit|deposits|received|paid\s*in|money\s*in)\b',
                caseSensitive: false)
            .hasMatch(colName);
        final isAmount = !isDebit &&
            !isCredit &&
            RegExp(r'\b(amount|amt|total)\b', caseSensitive: false)
                .hasMatch(colName);
        final isRef = RegExp(
                r'\b(chq|ref|cheque|reference|utr)\b',
                caseSensitive: false)
            .hasMatch(colName);
        final isBalance = RegExp(r'\b(balance|bal)\b', caseSensitive: false)
            .hasMatch(colName);

        if (isDate && dateIdx == -1) {
          dateIdx = c;
          matchCount++;
        } else if (isNarration && narrIdx == -1) {
          narrIdx = c;
          matchCount++;
        } else if (isDebit && debIdx == null) {
          debIdx = c;
          matchCount++;
        } else if (isCredit && credIdx == null) {
          credIdx = c;
          matchCount++;
        } else if (isAmount && amtIdx == null) {
          amtIdx = c;
          matchCount++;
        } else if (isRef && refIdx == null) {
          refIdx = c;
        } else if (isBalance && balIdx == null) {
          balIdx = c;
        }
      }

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

    // 2. Heuristic data-row scanner: If headers weren't found via text,
    // examine the data rows directly to identify date, narration, and amount columns
    for (int r = 0; r < rows.length && r < 40; r++) {
      final row = rows[r];
      if (row.length < 3) continue;

      int candidateDate = -1;
      int candidateNarr = -1;
      int candidateAmt = -1;

      for (int c = 0; c < row.length; c++) {
        final val = row[c].toString().trim();
        if (val.isEmpty) continue;

        if (candidateDate == -1 && parseFlexibleDate(val) != null) {
          candidateDate = c;
        } else if (candidateAmt == -1 && parseAmount(val) > 0) {
          candidateAmt = c;
        } else if (candidateNarr == -1 &&
            val.length >= 3 &&
            double.tryParse(val) == null) {
          candidateNarr = c;
        }
      }

      if (candidateDate != -1 && candidateAmt != -1) {
        indices.headerRowIndex = (r > 0) ? r - 1 : 0;
        indices.dateCol = candidateDate;
        indices.narrationCol = candidateNarr != -1
            ? candidateNarr
            : (candidateDate == 0 ? 1 : 0);
        indices.amountCol = candidateAmt;
        return indices;
      }
    }

    return indices;
  }

  /// Parses date string with various common bank formats using Review Inbox format rules
  static DateTime? parseFlexibleDate(String rawDate) {
    var clean = rawDate.trim();
    if (clean.isEmpty) return null;

    // 1. Strip time portion if present (e.g. "01/11/2024 10:30:00" -> "01/11/2024")
    final timeSplit = clean.split(RegExp(r'\s+'));
    if (timeSplit.isNotEmpty && timeSplit[0].length >= 6) {
      clean = timeSplit[0];
    }

    // 2. Format 1 from Review Inbox: DD-MM-YYYY or DD/MM/YYYY or DD-MM-YY or DD/MM/YY or DD.MM.YYYY
    // e.g. "04-11-26", "04/11/2026", "04-11-2026", "01/10/26"
    final numericDateRegex = RegExp(
      r'\b([0-3]?[0-9])[-/.]([0-1]?[0-9])[-/.](20[2-9][0-9]|[2-9][0-9])\b',
    );
    final numMatch = numericDateRegex.firstMatch(clean);
    if (numMatch != null) {
      int day = int.parse(numMatch.group(1)!);
      int month = int.parse(numMatch.group(2)!);
      int year = int.parse(numMatch.group(3)!);
      if (year < 100) year += 2000;
      if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
        return DateTime(year, month, day);
      }
    }

    // Format 2 from Review Inbox: DD-MMM-YY or DD-MMM-YYYY or DD MMM YYYY or DD-MMM
    // e.g. "04-Nov-26", "04-Nov-2026", "04 Nov 2026"
    final alphaDateRegex = RegExp(
      r'\b([0-3]?[0-9])[-/ ](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/ ]?(20[2-9][0-9]|[2-9][0-9])?\b',
      caseSensitive: false,
    );
    final alphaMatch = alphaDateRegex.firstMatch(clean);
    if (alphaMatch != null) {
      int day = int.parse(alphaMatch.group(1)!);
      int month = SmsParser.monthNumber(alphaMatch.group(2)!);
      int year = DateTime.now().year;
      if (alphaMatch.group(3) != null) {
        year = int.parse(alphaMatch.group(3)!);
        if (year < 100) year += 2000;
      }
      if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
        return DateTime(year, month, day);
      }
    }

    // Format 3 from Review Inbox: MMM DD, YYYY or MMM DD, YY e.g. "Nov 04, 2026", "Nov 04, 26"
    final mmmDdRegex = RegExp(
      r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+([0-3]?[0-9])(?:st|nd|rd|th)?,?\s*(20[2-9][0-9]|[2-9][0-9])?\b',
      caseSensitive: false,
    );
    final mmmDdMatch = mmmDdRegex.firstMatch(clean);
    if (mmmDdMatch != null) {
      int month = SmsParser.monthNumber(mmmDdMatch.group(1)!);
      int day = int.parse(mmmDdMatch.group(2)!);
      int year = DateTime.now().year;
      if (mmmDdMatch.group(3) != null) {
        year = int.parse(mmmDdMatch.group(3)!);
        if (year < 100) year += 2000;
      }
      if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
        return DateTime(year, month, day);
      }
    }

    // Format 4 from Review Inbox: ISO YYYY-MM-DD
    final isoRegex = RegExp(
      r'\b(20[2-9][0-9])[-/.]([0-1]?[0-9])[-/.]([0-3]?[0-9])\b',
    );
    final isoMatch = isoRegex.firstMatch(clean);
    if (isoMatch != null) {
      int year = int.parse(isoMatch.group(1)!);
      int month = int.parse(isoMatch.group(2)!);
      int day = int.parse(isoMatch.group(3)!);
      if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
        return DateTime(year, month, day);
      }
    }

    // 3. Fallback: Standard DateFormat list with 2-digit year protection (< 100 -> +2000)
    if (clean.contains('.')) {
      clean = clean.replaceAll('.', '/');
    }

    final formats = [
      "dd/MM/yy",
      "dd-MM-yy",
      "dd/MM/yyyy",
      "dd-MM-yyyy",
      "yyyy-MM-dd",
      "MM/dd/yy",
      "MM/dd/yyyy",
      "d/M/yy",
      "d/M/yyyy",
      "d-M-yy",
      "d-M-yyyy",
      "dd-MMM-yy",
      "dd/MMM/yy",
      "dd-MMM-yyyy",
      "dd MMM yyyy",
      "dd/MMM/yyyy",
      "yyyy/MM/dd",
      "MMM dd, yyyy",
      "MMMM dd, yyyy",
    ];

    for (final fmt in formats) {
      try {
        DateTime dt = DateFormat(fmt, 'en_US').parseLoose(clean);
        if (dt.year < 100) {
          dt = DateTime(dt.year + 2000, dt.month, dt.day, dt.hour, dt.minute);
        }
        return dt;
      } catch (_) {}
    }

    final parsed = DateTime.tryParse(clean);
    if (parsed != null) {
      if (parsed.year < 100) {
        return DateTime(parsed.year + 2000, parsed.month, parsed.day);
      }
      return parsed;
    }

    return null;
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

  /// Parses Excel (.xlsx / .xls) spreadsheet bytes, supporting OpenXML (.xlsx),
  /// native binary BIFF8 / OLE2 (.xls), HTML table statements (.xls), and XML Spreadsheet 2003.
  static Future<List<StatementEntry>> parseExcelBytes(
    List<int> bytes, {
    StatementColumnIndices? customIndices,
    String? targetWalletPk,
  }) async {
    // 1. Try native binary BIFF8 / OLE2 (.xls) parser (HDFC, SBI, ICICI, Axis statements)
    if (Biff8Parser.isOle2(bytes)) {
      try {
        final biffRows = Biff8Parser.parseRows(bytes);
        if (biffRows.isNotEmpty) {
          final entries = await parseRows(biffRows,
              customIndices: customIndices, targetWalletPk: targetWalletPk);
          if (entries.isNotEmpty) return entries;
        }
      } catch (biffErr) {
        debugPrint("Biff8 direct parse error: $biffErr");
      }
    }

    // 2. Try standard OpenXML .xlsx via pure-Dart Excel library
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
      debugPrint("OpenXML decode skipped, trying .xls HTML/XML/binary parser: $e");
    }

    // 3. Most bank .xls exports (e.g. SBI, HDFC, ICICI, Axis) are HTML tables or XML Spreadsheets
    String textContent = "";
    try {
      textContent = utf8.decode(bytes);
    } catch (_) {
      try {
        textContent = latin1.decode(bytes);
      } catch (_) {}
    }

    if (textContent.isNotEmpty) {
      // 3a. HTML Table saved with .xls extension
      if (textContent.contains("<table") ||
          textContent.contains("<TABLE") ||
          textContent.contains("<html") ||
          textContent.contains("<HTML") ||
          textContent.contains("<tr") ||
          textContent.contains("<TR")) {
        try {
          final doc = parseHtmlDocument(textContent);
          final tables = doc.querySelectorAll('table');
          for (final table in tables) {
            final trs = table.querySelectorAll('tr');
            if (trs.length >= 2) {
              final List<List<dynamic>> htmlRows = [];
              for (final tr in trs) {
                final cells = tr.querySelectorAll('th, td');
                if (cells.isNotEmpty) {
                  htmlRows.add(
                      cells.map((c) => c.text?.trim() ?? "").toList());
                }
              }
              if (htmlRows.length >= 2) {
                final tableEntries = await parseRows(htmlRows,
                    customIndices: customIndices,
                    targetWalletPk: targetWalletPk);
                if (tableEntries.isNotEmpty) {
                  return tableEntries;
                }
              }
            }
          }

          // If individual tables didn't yield transactions, run AI on the HTML text!
          final bodyText = doc.body?.text ?? textContent;
          if (bodyText.trim().length > 50) {
            final aiEntries = await parseStatementWithAi(bodyText,
                targetWalletPk: targetWalletPk);
            if (aiEntries.isNotEmpty) return aiEntries;
          }
        } catch (htmlErr) {
          debugPrint("HTML .xls table parsing error: $htmlErr");
        }
      }

      // 3b. XML Spreadsheet 2003 (<Workbook ... <Row><Cell><Data>...)
      if (textContent.contains("<Row") || textContent.contains("<row")) {
        try {
          final rowMatches = RegExp(r'<Row[^>]*>(.*?)</Row>',
                  dotAll: true, caseSensitive: false)
              .allMatches(textContent);
          if (rowMatches.isNotEmpty) {
            final List<List<dynamic>> xmlRows = [];
            for (final rm in rowMatches) {
              final rowInner = rm.group(1) ?? "";
              final cellMatches = RegExp(
                      r'<Cell[^>]*>.*?<Data[^>]*>(.*?)</Data>.*?</Cell>',
                      dotAll: true,
                      caseSensitive: false)
                  .allMatches(rowInner);
              final rowList = cellMatches
                  .map((cm) => (cm.group(1) ?? "")
                      .replaceAll(RegExp(r'<[^>]*>'), '')
                      .trim())
                  .toList();
              if (rowList.isNotEmpty) {
                xmlRows.add(rowList);
              }
            }
            if (xmlRows.length >= 2) {
              return await parseRows(xmlRows,
                  customIndices: customIndices,
                  targetWalletPk: targetWalletPk);
            }
          }
        } catch (xmlErr) {
          debugPrint("XML Spreadsheet .xls parsing error: $xmlErr");
        }
      }

      // 3c. Delimited text (CSV / TSV) saved with .xls extension
      if (textContent.contains(",") || textContent.contains("\t")) {
        try {
          final csvEntries = await parseCsv(textContent,
              customIndices: customIndices, targetWalletPk: targetWalletPk);
          if (csvEntries.isNotEmpty) return csvEntries;
        } catch (_) {}
      }
    }

    // 4. Binary OLE2 / BIFF8 (.xls) file fallback
    try {
      final binaryText = _extractTextFromBinaryXls(bytes);
      if (binaryText.isNotEmpty) {
        final entries = await parsePdfTextLines(binaryText,
            targetWalletPk: targetWalletPk);
        if (entries.isNotEmpty) return entries;
        return await parseStatementWithAi(binaryText,
            targetWalletPk: targetWalletPk);
      }
    } catch (biffErr) {
      debugPrint("Binary .xls extraction error: $biffErr");
    }

    return [];
  }

  /// Extracts readable UTF-16LE and ASCII text strings from binary OLE2 / BIFF8 (.xls) files
  static String _extractTextFromBinaryXls(List<int> bytes) {
    final buffer = StringBuffer();
    final len = bytes.length;

    // 1. Scan for UTF-16LE printable strings (common in BIFF8 SST records)
    for (int i = 0; i < len - 5; i += 2) {
      int j = i;
      while (j + 1 < len &&
          bytes[j] >= 32 &&
          bytes[j] <= 126 &&
          bytes[j + 1] == 0) {
        j += 2;
      }
      final strLen = (j - i) ~/ 2;
      if (strLen >= 3) {
        final chars = <int>[];
        for (int k = i; k < j; k += 2) {
          chars.add(bytes[k]);
        }
        final str = String.fromCharCodes(chars).trim();
        if (str.isNotEmpty &&
            !str.startsWith("Root Entry") &&
            !str.startsWith("Workbook") &&
            !str.startsWith("Current User")) {
          buffer.writeln(str);
        }
        i = j;
      }
    }

    // 2. Scan for 1-byte ASCII strings
    int i = 0;
    while (i < len) {
      int start = i;
      while (i < len && bytes[i] >= 32 && bytes[i] <= 126) {
        i++;
      }
      final sLen = i - start;
      if (sLen >= 3) {
        final str = String.fromCharCodes(bytes.sublist(start, i)).trim();
        if (str.isNotEmpty &&
            !str.startsWith("Root Entry") &&
            !str.startsWith("Workbook") &&
            !str.startsWith("Current User")) {
          buffer.writeln(str);
        }
      }
      i++;
    }
    return buffer.toString();
  }

  /// Extracts payment method from narration/message
  static String extractPaymentMethod(String text) {
    final upper = text.toUpperCase();
    if (upper.contains("UPI")) return "UPI";
    if (upper.contains("IMPS")) return "IMPS";
    if (upper.contains("NEFT")) return "NEFT";
    if (upper.contains("RTGS")) return "RTGS";
    if (upper.contains("ATM") || upper.contains("CASH WDL")) return "ATM Cash";
    if (upper.contains("POS") || upper.contains("SWIPE")) return "Debit Card / POS";
    if (upper.contains("BILLPAY") ||
        upper.contains("NETBANKING") ||
        upper.contains("IB BILLPAY")) return "Net Banking / BillPay";
    if (upper.contains("CREDIT CARD") || upper.contains("CARD")) return "Card";
    return "Bank Transfer";
  }

  static const Set<String> _invalidRefWords = {
    'AUTOPAY', 'MANDATE', 'TRANSFER', 'REFUND', 'REVERSAL',
    'RETURN', 'COLLECT', 'BILLPAY', 'BILL', 'MERCHANT',
    'PAYMENT', 'CREDIT', 'DEBIT', 'ONLINE', 'NETBANKING',
    'IMPS', 'NEFT', 'RTGS', 'UPI', 'PENDING', 'SUCCESS', 'FAILED',
    'KAMARAJ', 'MUTUAL', 'FUNDS', 'SALARY', 'INVOICE', 'PURCHASE'
  };

  /// Verifies if an extracted string represents a genuine banking reference ID.
  /// A valid banking reference (UPI RRN, UTR, Cheque No, Txn ID):
  /// - Must be 6 to 30 characters long
  /// - Must contain at least 2 numeric digits (never pure words like "AUTOPAY")
  /// - Must not be a known banking keyword
  static bool isValidReferenceId(String? ref) {
    if (ref == null) return false;
    final clean = ref.trim().toUpperCase();
    if (clean.length < 6 || clean.length > 30) return false;
    // Must contain at least 2 digits to be a legitimate banking transaction ID / RRN / UTR
    final digitCount = clean.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digitCount < 2) return false;
    // Cannot be a known banking keyword
    if (_invalidRefWords.contains(clean)) return false;
    return true;
  }

  /// Normalizes reference ID for robust comparison across statements and SMS:
  /// - Trims and converts to uppercase
  /// - Strips leading zeros from numeric or padded strings (e.g. 0000248122766849 -> 248122766849)
  /// - Removes formatting symbols (- / _)
  static String normalizeReferenceId(String? ref) {
    if (ref == null) return "";
    String clean = ref.trim().toUpperCase();
    clean = clean.replaceAll(RegExp(r'[\s\-_]'), '');
    if (!isValidReferenceId(clean)) return "";
    // If string has leading zeros followed by at least 6 digits/chars, strip the leading zeros
    final noZeros = clean.replaceFirst(RegExp(r'^0+'), '');
    if (noZeros.isNotEmpty && noZeros.length >= 6 && isValidReferenceId(noZeros)) {
      return noZeros;
    }
    return clean;
  }

  /// Determines whether two reference IDs refer to the same transaction
  static bool areReferenceIdsMatching(String? ref1, String? ref2) {
    if (ref1 == null || ref2 == null) return false;
    final n1 = normalizeReferenceId(ref1);
    final n2 = normalizeReferenceId(ref2);
    if (n1.isEmpty || n2.isEmpty) return false;

    // Exact normalized match (e.g. 0000248122766849 and 248122766849 both normalize to 248122766849)
    if (n1 == n2) return true;

    // Suffix / substring match for bank padding or embedded UPI RRN (min 8 digits)
    if (n1.length >= 8 && n2.length >= 8) {
      if (n1.endsWith(n2) || n2.endsWith(n1)) return true;
      if (n1.contains(n2) || n2.contains(n1)) return true;
    }
    return false;
  }

  /// Checks if two notes share a common transaction reference / RRN embedded in their narrations
  static bool notesShareReferenceId(String? note1, String? note2) {
    if (note1 == null || note2 == null || note1.isEmpty || note2.isEmpty) {
      return false;
    }
    final r1 = extractReferenceId(note1);
    final r2 = extractReferenceId(note2);
    if (r1 != null && r2 != null && areReferenceIdsMatching(r1, r2)) return true;

    final n1 = normalizeReferenceId(r1);
    final n2 = normalizeReferenceId(r2);
    if (n1.length >= 8 && note2.toUpperCase().contains(n1)) return true;
    if (n2.length >= 8 && note1.toUpperCase().contains(n2)) return true;

    return false;
  }

  /// Extracts reference ID (UPI Ref, UTR, Cheque No, Transaction ID)
  static String? extractReferenceId(String text, {String? explicitRef}) {
    if (explicitRef != null && explicitRef.trim().isNotEmpty) {
      final clean = explicitRef.trim();
      if (clean != "-" && clean != "NA" && clean != "null" && isValidReferenceId(clean)) {
        return normalizeReferenceId(clean);
      }
    }
    // Pattern 1: Explicit Ref ID:, Ref no:, Txn ID:, UTR:, CMS:, Chq/Ref: ...
    final refPatterns = [
      RegExp(
          r'(?:Ref(?:\s*(?:ID|no|num|number))?|Txn(?:\s*id)?|UTR|CMS|Chq(?:\s*no)?)[:\s\/\-]+([A-Za-z0-9]{6,24})',
          caseSensitive: false),
      // Pattern 2: 12-digit standard UPI RRN (Retrieval Reference Number)
      RegExp(r'\b([0-9]{12})\b'),
      // Pattern 3: Cheque / ref numbers with leading zeros like 0000185387200991 or 0000104390793818
      RegExp(r'\b(0000[0-9]{8,14})\b'),
      // Pattern 4: 12 to 18 digit transaction reference numbers
      RegExp(r'\b([0-9]{12,18})\b'),
      // Pattern 5: Alphanumeric UTR with bank prefix e.g. HDFCN23019284721
      RegExp(r'\b([A-Z]{4}[0-9]{10,18})\b', caseSensitive: false),
    ];

    for (final reg in refPatterns) {
      final match = reg.firstMatch(text);
      if (match != null) {
        final val = match.group(1);
        if (val != null && isValidReferenceId(val)) {
          return normalizeReferenceId(val);
        }
      }
    }
    return null;
  }

  /// Checks whether a PDF document requires a password to open
  static bool isPdfEncrypted(List<int> bytes) {
    if (bytes.length < 50) return false;
    try {
      // Fast raw byte signature check for PDF encryption dictionary
      final headLen = math.min(bytes.length, 32768);
      final tailLen = math.min(bytes.length, 8192);
      final head = latin1.decode(bytes.sublist(0, headLen));
      final tail = latin1.decode(bytes.sublist(bytes.length - tailLen));
      if (head.contains('/Encrypt') || tail.contains('/Encrypt')) {
        return true;
      }
    } catch (_) {}

    try {
      final doc = PdfDocument(inputBytes: bytes);
      doc.dispose();
      return false;
    } catch (e) {
      final errStr = e.toString().toLowerCase();
      return errStr.contains('encrypted') ||
          errStr.contains('password') ||
          errStr.contains('cannot open an encrypted document');
    }
  }

  /// Parses digital PDF statement bytes (bank and credit card statements),
  /// supporting password-protected bank statements.
  static Future<List<StatementEntry>> parsePdfBytes(
    List<int> bytes, {
    StatementColumnIndices? customIndices,
    String? targetWalletPk,
    String? password,
  }) async {
    try {
      final document = PdfDocument(inputBytes: bytes, password: password);
      final extractor = PdfTextExtractor(document);
      final fullText = extractor.extractText();
      document.dispose();

      if (fullText.trim().isEmpty) return [];

      lastExtractedSummary = extractCreditCardSummary(fullText);

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
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('encrypted') ||
          errStr.contains('password') ||
          errStr.contains('cannot open an encrypted document')) {
        throw PdfPasswordException(
          password == null || password.isEmpty
              ? "This PDF statement is password protected."
              : "Incorrect password. Please verify and try again.",
          isIncorrect: password != null && password.isNotEmpty,
        );
      }
    }
    return [];
  }

  /// Robust table and line parser for structured bank & credit card statement text
  static Future<List<StatementEntry>> parsePdfTextLines(
    String fullText, {
    String? targetWalletPk,
  }) async {
    final rawLines = fullText.split('\n');
    final List<StatementEntry> entries = [];

    // Date pattern matching beginning of transaction rows
    final rowDateRegex = RegExp(
      r'^\s*([0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4}|[0-3]?[0-9]\s+[A-Za-z]{3}\s+[0-9]{2,4}|[0-3]?[0-9]-[A-Za-z]{3}-[0-9]{2,4})',
      caseSensitive: false,
    );

    // Number extractor (amounts with optional decimals, commas, and Cr/Dr indicators)
    final amountPattern = RegExp(
      r'([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2}))(?:\s*(Cr|Dr|Credit|Debit))?',
      caseSensitive: false,
    );

    for (int lineIdx = 0; lineIdx < rawLines.length; lineIdx++) {
      final line = rawLines[lineIdx].trim();
      if (line.isEmpty) continue;

      // Skip common non-transaction headers and summary lines
      final lower = line.toLowerCase();
      if (lower.contains("statement of accounts") ||
          lower.contains("account branch") ||
          lower.contains("rtgs/neft ifsc") ||
          lower.contains("od limit") ||
          lower.contains("opening balance") ||
          lower.contains("closing balance") ||
          lower.contains("total amount due") ||
          lower.contains("credit limit") ||
          lower.contains("available credit") ||
          line.startsWith("******") ||
          line.startsWith("------")) {
        continue;
      }

      final dateMatch = rowDateRegex.firstMatch(line);
      if (dateMatch == null) {
        // Multi-line continuation: If previous entry exists and this line looks like narrative details, append
        if (entries.isNotEmpty &&
            !line.contains(RegExp(r'^\s*[0-9]+(?:\.[0-9]{2})?$'))) {
          final prev = entries.last;
          if (prev.rawNarration.length < 300) {
            prev.rawNarration += " " + line;
          }
        }
        continue;
      }

      final dateStr = dateMatch.group(1)!;
      final date = parseFlexibleDate(dateStr);
      if (date == null) continue;

      // Remainder of line after the primary transaction date
      String remainder = line.substring(dateMatch.end).trim();

      // Find all amount candidates
      final allAmountMatches = amountPattern.allMatches(remainder).toList();
      if (allAmountMatches.isEmpty) continue;

      double? txnAmount;
      double? balance;
      bool isIncome = false;
      String? explicitRef;

      // In Indian bank statements (Date | Narration | Chq/Ref | Value Date | Withdrawal | Deposit | Closing Balance):
      // The LAST valid number is Closing Balance.
      // The preceding number is the Transaction Amount.
      if (allAmountMatches.length >= 2) {
        final lastMatch = allAmountMatches.last;
        final lastVal = parseAmount(lastMatch.group(1)!);
        final secondLastMatch = allAmountMatches[allAmountMatches.length - 2];
        final secondLastVal = parseAmount(secondLastMatch.group(1)!);

        if (secondLastVal > 0) {
          txnAmount = secondLastVal;
          balance = lastVal;

          final indicator = (secondLastMatch.group(2) ?? lastMatch.group(2))
              ?.toLowerCase();
          if (indicator == "cr" || indicator == "credit") {
            isIncome = true;
          } else if (indicator == "dr" || indicator == "debit") {
            isIncome = false;
          } else {
            if (lower.contains("deposit") ||
                lower.contains("cr-") ||
                lower.contains("credited") ||
                lower.contains("salary") ||
                lower.contains("interest")) {
              isIncome = true;
            } else {
              isIncome = false;
            }
          }
        }
      } else if (allAmountMatches.length == 1) {
        final m = allAmountMatches.first;
        final val = parseAmount(m.group(1)!);
        if (val > 0) {
          txnAmount = val;
          final indicator = m.group(2)?.toLowerCase();
          isIncome = indicator == "cr" || indicator == "credit";
        }
      }

      if (txnAmount == null || txnAmount <= 0) continue;

      // Extract Reference number from line
      explicitRef = extractReferenceId(remainder);

      // Extract Narration: everything before the first amount match
      final firstAmtStart = allAmountMatches.first.start;
      String narr =
          remainder.substring(0, math.min(remainder.length, firstAmtStart)).trim();
      if (narr.isEmpty) {
        narr = remainder;
      }

      narr = narr.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (narr.isEmpty) narr = "Bank Transaction";

      final lowerNarr = narr.toLowerCase();
      final isCash = isCashWithdrawalNarration(narr);
      final isInterest = lowerNarr.contains("finance charge") ||
          lowerNarr.contains("interest charge") ||
          lowerNarr.contains("interest on purchase") ||
          lowerNarr.contains("fc @");
      final isGst = lowerNarr.contains("igst") ||
          lowerNarr.contains("cgst") ||
          lowerNarr.contains("sgst") ||
          lowerNarr.contains("gst on");
      final isEmi = lowerNarr.contains("emi ") ||
          lowerNarr.contains("smart emi") ||
          lowerNarr.contains("merchant emi") ||
          lowerNarr.contains("loan on card");

      String cleanMerchant;
      String catName;
      String? catPk;
      String? subCatName;
      String? subCatPk;
      double confidence;

      if (isCash) {
        cleanMerchant = "ATM Cash Withdrawal";
        catName = "Cash & ATM";
        confidence = 0.99;
      } else {
        cleanMerchant = isInterest
            ? "Finance Charges / Interest"
            : (isGst
                ? "GST on Finance Charges"
                : AiCategorizer.cleanMerchantName(narr));
        final aiSuggestion = await AiCategorizer.categorize(
          rawTitle: narr,
          isIncome: isIncome,
        );
        catName = aiSuggestion.categoryName;
        catPk = aiSuggestion.categoryPk;
        subCatName = aiSuggestion.subCategoryName;
        subCatPk = aiSuggestion.subCategoryPk;
        confidence = aiSuggestion.confidence;
      }

      entries.add(
        StatementEntry(
          date: date,
          rawNarration: narr,
          cleanMerchant: cleanMerchant,
          amount: txnAmount,
          isIncome: isIncome,
          referenceNo: explicitRef,
          balance: balance,
          suggestedCategoryName: catName,
          suggestedCategoryPk: catPk,
          suggestedSubCategoryName: subCatName,
          suggestedSubCategoryPk: subCatPk,
          confidence: confidence,
          isCashWithdrawal: isCash,
          isTransferToCash: isCash,
          isCreditCardInterest: isInterest,
          isCreditCardGst: isGst,
          isCreditCardEmi: isEmi,
        ),
      );
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
            final aiSuggestion = await AiCategorizer.categorize(
              rawTitle: desc.isNotEmpty ? desc : cleanMerchant,
              isIncome: isIncome,
            );

            entries.add(
              StatementEntry(
                date: date,
                rawNarration: desc,
                cleanMerchant: cleanMerchant,
                amount: amt,
                isIncome: isIncome,
                suggestedCategoryName: aiSuggestion.categoryName,
                suggestedCategoryPk: aiSuggestion.categoryPk,
                suggestedSubCategoryName: aiSuggestion.subCategoryName,
                suggestedSubCategoryPk: aiSuggestion.subCategoryPk,
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

      // Check for Cash / ATM withdrawal and Credit Card charges
      final lowerNarr = rawNarr.toLowerCase();
      final isCash = isCashWithdrawalNarration(rawNarr);
      final isInterest = lowerNarr.contains("finance charge") ||
          lowerNarr.contains("interest charge") ||
          lowerNarr.contains("interest on purchase") ||
          lowerNarr.contains("fc @");
      final isGst = lowerNarr.contains("igst") ||
          lowerNarr.contains("cgst") ||
          lowerNarr.contains("sgst") ||
          lowerNarr.contains("gst on");
      final isEmi = lowerNarr.contains("emi ") ||
          lowerNarr.contains("smart emi") ||
          lowerNarr.contains("merchant emi") ||
          lowerNarr.contains("loan on card");

      String cleanMerchant;
      String catName;
      String? catPk;
      String? subCatName;
      String? subCatPk;
      double confidence;

      if (isCash) {
        cleanMerchant = "ATM Cash Withdrawal";
        catName = "Cash & ATM";
        confidence = 0.99;
      } else {
        cleanMerchant = isInterest
            ? "Finance Charges / Interest"
            : (isGst
                ? "GST on Finance Charges"
                : AiCategorizer.cleanMerchantName(rawNarr));
        final aiSuggestion = await AiCategorizer.categorize(
          rawTitle: rawNarr,
          isIncome: isIncome,
        );
        catName = aiSuggestion.categoryName;
        catPk = aiSuggestion.categoryPk;
        subCatName = aiSuggestion.subCategoryName;
        subCatPk = aiSuggestion.subCategoryPk;
        confidence = aiSuggestion.confidence;
      }

      entries.add(
        StatementEntry(
          date: date,
          rawNarration: rawNarr,
          cleanMerchant: cleanMerchant,
          amount: amount,
          isIncome: isIncome,
          referenceNo: refNo,
          balance: bal,
          suggestedCategoryName: catName,
          suggestedCategoryPk: catPk,
          suggestedSubCategoryName: subCatName,
          suggestedSubCategoryPk: subCatPk,
          confidence: confidence,
          isCashWithdrawal: isCash,
          isTransferToCash: isCash,
          isCreditCardInterest: isInterest,
          isCreditCardGst: isGst,
          isCreditCardEmi: isEmi,
        ),
      );
    }

    // Reconcile against both database transactions and Review Inbox
    if (targetWalletPk != null && targetWalletPk.isNotEmpty) {
      await checkDuplicates(entries, targetWalletPk);
    }

    return entries;
  }

  /// Generates deterministic IDs for each statement entry based on account, date, amount, flow, and occurrence
  static void assignDeterministicIds(List<StatementEntry> entries,
      {String? walletPk}) {
    final Map<String, int> occurrenceMap = {};
    final wPk = walletPk ?? "0";
    for (int i = 0; i < entries.length; i++) {
      final e = entries[i];
      final key =
          "${wPk}_${e.date.year}${e.date.month.toString().padLeft(2, '0')}${e.date.day.toString().padLeft(2, '0')}_${(e.amount.abs() * 100).toInt()}_${e.isIncome ? 'cr' : 'dr'}";
      final occ = occurrenceMap[key] ?? 0;
      occurrenceMap[key] = occ + 1;
      e.id = "stmt_${key}_$occ";
    }
  }

  /// Checks existing transactions in wallet and Review Inbox to reconcile and flag duplicates
  static Future<void> checkDuplicates(
    List<StatementEntry> entries,
    String walletPk,
  ) async {
    if (entries.isEmpty) return;
    assignDeterministicIds(entries, walletPk: walletPk);

    DateTime minDate = entries.first.date;
    DateTime maxDate = entries.first.date;
    for (final e in entries) {
      if (e.date.isBefore(minDate)) minDate = e.date;
      if (e.date.isAfter(maxDate)) maxDate = e.date;
    }

    // Expand search window by 3 days for bank settlement differences
    final searchStart = minDate.subtract(const Duration(days: 3));
    final searchEnd = maxDate.add(const Duration(days: 3));

    // 1. Reconcile against persisted transactions in SQLite database
    final walletTransactions =
        await database.getAllTransactionsFromWallet(walletPk);

    // Auto-heal any legacy transactions previously imported with 2-digit years (< 100)
    for (int i = 0; i < walletTransactions.length; i++) {
      final t = walletTransactions[i];
      if (t.dateCreated.year < 100) {
        final corrected = DateTime(
          t.dateCreated.year + 2000,
          t.dateCreated.month,
          t.dateCreated.day,
          t.dateCreated.hour,
          t.dateCreated.minute,
        );
        try {
          await database.createOrUpdateTransaction(
            t.copyWith(dateCreated: corrected),
            insert: false,
          );
          walletTransactions[i] = t.copyWith(dateCreated: corrected);
        } catch (_) {}
      }
    }

    final existing = walletTransactions
        .where((t) =>
            t.dateCreated.isAfter(searchStart) &&
            t.dateCreated.isBefore(searchEnd))
        .toList();

    // 2. Reconcile against pending SMS in Review Inbox
    final pendingSms = ReviewManager.instance.pendingTransactions;

    for (final entry in entries) {
      final entryDateOnly =
          DateTime(entry.date.year, entry.date.month, entry.date.day);

      // Check SQLite DB
      bool matched = false;
      for (final tx in existing) {
        final txDateOnly = DateTime(
            tx.dateCreated.year, tx.dateCreated.month, tx.dateCreated.day);
        final diffDays = entryDateOnly.difference(txDateOnly).inDays.abs();
        final amountMatches = (tx.amount.abs() - entry.amount).abs() < 0.01;
        final typeMatches = (tx.income == entry.isIncome);

        if (amountMatches && typeMatches) {
          final dbRef = extractReferenceId(tx.note);
          final entryRef =
              entry.referenceNo ?? extractReferenceId(entry.rawNarration);

          final refsMatch = areReferenceIdsMatching(dbRef, entryRef) ||
              notesShareReferenceId(tx.note, entry.rawNarration);

          if (dbRef != null && entryRef != null && dbRef.isNotEmpty && entryRef.isNotEmpty) {
            if (!refsMatch) {
              // Different reference IDs on same day: legitimate distinct transactions!
              continue;
            }
          }

          // If reference IDs match, allow up to 4 days difference (bank value date / clearing delays)
          // Otherwise, require within 2 calendar days
          final maxDays = refsMatch ? 4 : 2;
          if (diffDays <= maxDays) {
            entry.duplicateState = DuplicateState.confirmedDuplicate;
            entry.matchedSource = 'database';
            entry.isSelected = false; // Deselect already-reconciled items
            final displayRef = entryRef ?? dbRef;
            entry.duplicateReason =
                "Reconciled with existing '${tx.name}' (${DateFormat('dd MMM').format(tx.dateCreated)})" +
                    (displayRef != null ? " [Ref: $displayRef]" : "");
            matched = true;
            break;
          }
        }
      }

      if (!matched) {
        // Check Review Inbox pending SMS
        for (final item in pendingSms) {
          final itemDateOnly =
              DateTime(item.date.year, item.date.month, item.date.day);
          final diffDays = entryDateOnly.difference(itemDateOnly).inDays.abs();
          final amountMatches = (item.amount.abs() - entry.amount).abs() < 0.01;
          final typeMatches = (item.isIncome == entry.isIncome);

          if (amountMatches && typeMatches) {
            final smsRef = extractReferenceId(item.rawMessage);
            final entryRef =
                entry.referenceNo ?? extractReferenceId(entry.rawNarration);

            final refsMatch = areReferenceIdsMatching(smsRef, entryRef) ||
                notesShareReferenceId(item.rawMessage, entry.rawNarration);

            if (smsRef != null && entryRef != null && smsRef.isNotEmpty && entryRef.isNotEmpty) {
              if (!refsMatch) {
                // Different reference IDs on same day: legitimate distinct transactions!
                continue;
              }
            }

            final maxDays = refsMatch ? 4 : 2;
            if (diffDays <= maxDays) {
              entry.duplicateState = DuplicateState.potentialDuplicate;
              entry.matchedSource = 'review_inbox';
              entry.isSelected = false;
              final displayRef = entryRef ?? smsRef;
              entry.duplicateReason =
                  "Matches pending SMS in Review Inbox: '${item.cleanMerchant}' (${DateFormat('dd MMM').format(item.date)})" +
                      (displayRef != null ? " [Ref: $displayRef]" : "");
              matched = true;
              break;
            }
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
