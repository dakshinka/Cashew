import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/statementImporter/statementModels.dart';
import 'package:budget/struct/statementImporter/statementParser.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';

class StatementTemplate {
  final String id;
  final String name;
  final List<String> signatures;
  final String? regexTotalDue;
  final String? regexMinDue;
  final String? regexDueDate;
  final String? regexStatementDate;
  final String? regexBillingPeriod;
  final String? regexCardNumber;
  final String? regexFourBlock;
  final String? regexLimitBlock;
  final String? regexGst;
  final String? regexTransactions;
  final bool isBuiltIn;

  StatementTemplate({
    required this.id,
    required this.name,
    required this.signatures,
    this.regexTotalDue,
    this.regexMinDue,
    this.regexDueDate,
    this.regexStatementDate,
    this.regexBillingPeriod,
    this.regexCardNumber,
    this.regexFourBlock,
    this.regexLimitBlock,
    this.regexGst,
    this.regexTransactions,
    this.isBuiltIn = false,
  });

  bool matchesText(String text) {
    final lower = text.toLowerCase();
    for (final sig in signatures) {
      if (!lower.contains(sig.toLowerCase())) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'signatures': signatures,
        'regexTotalDue': regexTotalDue,
        'regexMinDue': regexMinDue,
        'regexDueDate': regexDueDate,
        'regexStatementDate': regexStatementDate,
        'regexBillingPeriod': regexBillingPeriod,
        'regexCardNumber': regexCardNumber,
        'regexFourBlock': regexFourBlock,
        'regexLimitBlock': regexLimitBlock,
        'regexGst': regexGst,
        'regexTransactions': regexTransactions,
        'isBuiltIn': isBuiltIn,
      };

  factory StatementTemplate.fromJson(Map<String, dynamic> json) =>
      StatementTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        signatures: (json['signatures'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [],
        regexTotalDue: json['regexTotalDue'] as String?,
        regexMinDue: json['regexMinDue'] as String?,
        regexDueDate: json['regexDueDate'] as String?,
        regexStatementDate: json['regexStatementDate'] as String?,
        regexBillingPeriod: json['regexBillingPeriod'] as String?,
        regexCardNumber: json['regexCardNumber'] as String?,
        regexFourBlock: json['regexFourBlock'] as String?,
        regexLimitBlock: json['regexLimitBlock'] as String?,
        regexGst: json['regexGst'] as String?,
        regexTransactions: json['regexTransactions'] as String?,
        isBuiltIn: (json['isBuiltIn'] as bool?) ?? false,
      );
}

class StatementTemplateManager {
  static final StatementTemplateManager instance =
      StatementTemplateManager._internal();

  StatementTemplateManager._internal() {
    _initBuiltInTemplates();
  }

  final List<StatementTemplate> _builtInTemplates = [];
  final List<StatementTemplate> _learnedTemplates = [];
  bool _isLoaded = false;

  void _initBuiltInTemplates() {
    // 1. HDFC RuPay / Credit Card Statement Template
    _builtInTemplates.add(
      StatementTemplate(
        id: "hdfc_rupay_card",
        name: "HDFC RuPay / Credit Card Statement",
        signatures: ["hdfc bank", "rupay credit card"],
        regexTotalDue:
            r'TOTAL\s*AMOUNT\s*DUE\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexMinDue:
            r'MINIMUM\s*(?:AMOUNT\s*)?DUES?\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexDueDate:
            r'DUE\s*DATE\s*[:\-]?\s*([0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}|[0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4})',
        regexStatementDate:
            r'([0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4})\s*(?:[0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}\s*-\s*[0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4})',
        regexBillingPeriod:
            r'([0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}\s*-\s*[0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}|[0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4}\s*(?:to|-)\s*[0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4})',
        regexCardNumber: r'([0-9]{4,6}[X*]{4,10}[0-9]{4})',
        regexFourBlock:
            r'PREVIOUS\s*STATEMENT\s*DUES.*?PAYMENTS.*?PURCHASES.*?FINANCE\s*CHARGES\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexLimitBlock:
            r'TOTAL\s*CREDIT\s*LIMIT.*?AVAILABLE\s*CREDIT\s*LIMIT.*?AVAILABLE\s*CASH\s*LIMIT\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexGst:
            r'GST\s*Summary.*?TOTAL\s*GST\s*[C₹Rs\.INR]*[0-9,.]*\s*[C₹Rs\.INR]*[0-9,.]*\s*[C₹Rs\.INR]*[0-9,.]*\s*[C₹Rs\.INR]*[0-9,.]*\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexTransactions:
            r'([0-3]?[0-9]\/[0-1]?[0-9]\/[0-9]{4})(?:\|\s*[0-2]?[0-9]:[0-5][0-9])?\s*(.*?)(?:\+\s*)?[C₹Rs\.INR\s]+([0-9,]+(?:\.[0-9]{2})?)(?=[l\n\r]|$)',
        isBuiltIn: true,
      ),
    );

    // 2. Generic Standard Credit Card Statement Template (flexible multi-bank)
    _builtInTemplates.add(
      StatementTemplate(
        id: "generic_credit_card",
        name: "Standard Credit Card Statement",
        signatures: ["credit card", "statement"],
        regexTotalDue:
            r'(?:total\s*amount\s*due|total\s*due|net\s*amount\s*payable)\s*[:\-]?\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexMinDue:
            r'(?:minimum\s*amount\s*due|min\s*due|minimum\s*due|mad)\s*[:\-]?\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
        regexDueDate:
            r'(?:payment\s*due\s*date|due\s*date|pay\s*by\s*date)\s*[:\-]?\s*([0-3]?[0-9][\s\/\-.][A-Za-z0-9,\s\-]+)',
        regexStatementDate:
            r'(?:statement\s*date|billing\s*date|bill\s*date)\s*[:\-]?\s*([0-3]?[0-9][\s\/\-.][A-Za-z0-9,\s\-]+)',
        regexBillingPeriod:
            r'(?:billing\s*period|statement\s*period)\s*[:\-]?\s*([^\n\r]+)',
        regexCardNumber: r'([0-9]{4,6}[X*]{4,10}[0-9]{4})',
        regexFourBlock:
            r'(?:previous\s*dues?|opening\s*balance).*?([0-9,]+(?:\.[0-9]{2})?).*?(?:payments?|credits?).*?([0-9,]+(?:\.[0-9]{2})?).*?(?:purchases?|debits?).*?([0-9,]+(?:\.[0-9]{2})?).*?(?:finance|interest).*?([0-9,]+(?:\.[0-9]{2})?)',
        regexLimitBlock:
            r'(?:total\s*)?credit\s*limit.*?([0-9,]+(?:\.[0-9]{2})?).*?available\s*credit.*?([0-9,]+(?:\.[0-9]{2})?)',
        regexGst:
            r'(?:total\s*gst|total\s*taxes|igst|cgst).*?([0-9,]+(?:\.[0-9]{2})?)',
        isBuiltIn: true,
      ),
    );
  }

  void _loadLearnedTemplates() {
    if (_isLoaded) return;
    try {
      final raw =
          sharedPreferences.getString("learned_statement_templates") ?? "[]";
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _learnedTemplates.clear();
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            _learnedTemplates.add(StatementTemplate.fromJson(item));
          }
        }
      }
      _isLoaded = true;
    } catch (_) {
      // Ignored if sharedPreferences is uninitialized
    }
  }

  Future<void> saveLearnedTemplate(StatementTemplate template) async {
    _loadLearnedTemplates();
    _learnedTemplates.removeWhere((t) => t.id == template.id);
    _learnedTemplates.insert(0, template);
    try {
      final jsonList = _learnedTemplates.map((t) => t.toJson()).toList();
      await sharedPreferences.setString(
          "learned_statement_templates", jsonEncode(jsonList));
      debugPrint(
          "Saved learned statement template: ${template.name} (${template.id})");
    } catch (_) {}
  }

  /// Tries extracting metadata using registered templates (Learned + Built-in)
  CreditCardStatementSummary? extractWithTemplates(String text) {
    _loadLearnedTemplates();

    // Priority 1: Check learned templates
    for (final template in _learnedTemplates) {
      if (template.matchesText(text)) {
        final summary = _applyTemplate(template, text);
        if (summary != null && summary.hasData) {
          return summary;
        }
      }
    }

    // Priority 2: Check built-in templates
    for (final template in _builtInTemplates) {
      if (template.matchesText(text)) {
        final summary = _applyTemplate(template, text);
        if (summary != null && summary.hasData) {
          return summary;
        }
      }
    }

    return null;
  }

  CreditCardStatementSummary? _applyTemplate(
      StatementTemplate template, String text) {
    double? totalDue;
    if (template.regexTotalDue != null) {
      final m = RegExp(template.regexTotalDue!, caseSensitive: false)
          .firstMatch(text);
      if (m != null) totalDue = StatementParser.parseAmount(m.group(1)!);
    }

    double? minDue;
    if (template.regexMinDue != null) {
      final m = RegExp(template.regexMinDue!, caseSensitive: false)
          .firstMatch(text);
      if (m != null) minDue = StatementParser.parseAmount(m.group(1)!);
    }

    DateTime? dueDate;
    if (template.regexDueDate != null) {
      final m = RegExp(template.regexDueDate!, caseSensitive: false)
          .firstMatch(text);
      if (m != null) dueDate = StatementParser.parseFlexibleDate(m.group(1)!);
    }

    DateTime? stmtDate;
    if (template.regexStatementDate != null) {
      final m = RegExp(template.regexStatementDate!, caseSensitive: false)
          .firstMatch(text);
      if (m != null) stmtDate = StatementParser.parseFlexibleDate(m.group(1)!);
    }

    String? billingPeriod;
    if (template.regexBillingPeriod != null) {
      final m = RegExp(template.regexBillingPeriod!, caseSensitive: false)
          .firstMatch(text);
      if (m != null) billingPeriod = m.group(1)!.trim();
    }

    String? cardLast4;
    if (template.regexCardNumber != null) {
      final m = RegExp(template.regexCardNumber!, caseSensitive: false)
          .firstMatch(text);
      if (m != null) {
        final full = m.group(1)!;
        cardLast4 = full.length >= 4 ? full.substring(full.length - 4) : full;
      }
    }

    double? prevDue;
    double? payments;
    double? debits;
    double? finance;
    if (template.regexFourBlock != null) {
      final m = RegExp(template.regexFourBlock!,
              caseSensitive: false, dotAll: true)
          .firstMatch(text);
      if (m != null) {
        prevDue = StatementParser.parseAmount(m.group(1)!);
        payments = StatementParser.parseAmount(m.group(2)!);
        debits = StatementParser.parseAmount(m.group(3)!);
        finance = StatementParser.parseAmount(m.group(4)!);
      }
    }

    double? totalLimit;
    double? avlCredit;
    double? avlCash;
    if (template.regexLimitBlock != null) {
      final m = RegExp(template.regexLimitBlock!,
              caseSensitive: false, dotAll: true)
          .firstMatch(text);
      if (m != null) {
        totalLimit = StatementParser.parseAmount(m.group(1)!);
        if (m.groupCount >= 2) {
          avlCredit = StatementParser.parseAmount(m.group(2)!);
        }
        if (m.groupCount >= 3) {
          avlCash = StatementParser.parseAmount(m.group(3)!);
        }
      }
    }

    double? gst;
    if (template.regexGst != null) {
      final m =
          RegExp(template.regexGst!, caseSensitive: false, dotAll: true)
              .firstMatch(text);
      if (m != null) gst = StatementParser.parseAmount(m.group(1)!);
    }

    return CreditCardStatementSummary(
      cardName: template.name,
      cardLast4: cardLast4,
      statementDate: stmtDate,
      dueDate: dueDate,
      billingPeriod: billingPeriod,
      totalAmountDue: totalDue,
      minAmountDue: minDue,
      previousStatementDue: prevDue,
      paymentsReceived: payments,
      purchasesCurrentCycle: debits,
      financeCharges: finance,
      gstCharges: gst,
      totalCreditLimit: totalLimit,
      availableCreditLimit: avlCredit,
      availableCashLimit: avlCash,
      extractedVia: "template:${template.id}",
    );
  }

  /// Extracts transactions using matched template if regexTransactions is provided
  List<StatementEntry>? extractTransactionsWithTemplate(
    String text, {
    String? targetWalletPk,
  }) {
    _loadLearnedTemplates();
    final allTemplates = [..._learnedTemplates, ..._builtInTemplates];

    for (final template in allTemplates) {
      if (template.matchesText(text) && template.regexTransactions != null) {
        final reg = RegExp(template.regexTransactions!, caseSensitive: false);
        final matches = reg.allMatches(text);
        if (matches.length >= 2) {
          final List<StatementEntry> list = [];
          for (final m in matches) {
            final dateStr = m.group(1) ?? "";
            final date = StatementParser.parseFlexibleDate(dateStr) ??
                DateTime.now();
            final rawDesc = m.group(2)?.trim() ?? "Transaction";
            final amtStr = m.group(3) ?? "0";
            final amt = StatementParser.parseAmount(amtStr);
            if (amt <= 0) continue;

            final upperDesc = rawDesc.toUpperCase();
            final isIncome = upperDesc.contains("PAYMENT") ||
                upperDesc.contains("REFUND") ||
                upperDesc.contains("CASHBACK") ||
                m.group(0)!.contains("+");

            final isInterest = upperDesc.contains("FINANCE CHARGE") ||
                upperDesc.contains("INTEREST CHARGE");
            final isGst =
                upperDesc.contains("CGST") || upperDesc.contains("SGST");
            final isEmi = upperDesc.contains("EMI");

            String ref = "";
            final refM = RegExp(r'Ref#?\s*([A-Za-z0-9]+)').firstMatch(rawDesc);
            if (refM != null) ref = refM.group(1)!;

            final cleanMerchant = AiCategorizer.cleanMerchantName(rawDesc);

            list.add(
              StatementEntry(
                date: date,
                rawNarration: rawDesc,
                cleanMerchant: cleanMerchant,
                amount: amt,
                isIncome: isIncome,
                referenceNo: ref.isNotEmpty ? ref : null,
                suggestedCategoryName: isIncome
                    ? "Payment"
                    : (isInterest
                        ? "Interest & Finance"
                        : (isGst ? "Taxes" : "Uncategorized")),
                isCreditCardInterest: isInterest,
                isCreditCardGst: isGst,
                isCreditCardEmi: isEmi,
              ),
            );
          }
          if (list.isNotEmpty) return list;
        }
      }
    }
    return null;
  }

  /// AI-assisted extractor that reads new or unrecognized credit card statements,
  /// extracts all summary metrics, and creates/saves a learned template for future uploads!
  Future<CreditCardStatementSummary?> extractWithLlmAndLearnTemplate(
      String fullText) async {
    try {
      final sample = fullText.length > 4000
          ? fullText.substring(0, 4000)
          : fullText;

      final prompt = '''
You are an expert financial document intelligence system.
Analyze this credit card statement header and summary text.
Extract all key credit card billing figures into a clean JSON object.

Text:
"""
$sample
"""

Respond ONLY with valid JSON in this exact structure:
{
  "bankOrCardName": "HDFC UPI RuPay Credit Card",
  "cardLast4": "2485",
  "statementDate": "YYYY-MM-DD",
  "dueDate": "YYYY-MM-DD",
  "billingPeriod": "15 Sep 2026 - 14 Oct 2026",
  "totalAmountDue": 112938.00,
  "minAmountDue": 5650.00,
  "previousStatementDue": 107255.63,
  "paymentsReceived": 5370.00,
  "purchasesCurrentCycle": 7123.62,
  "financeCharges": 3928.99,
  "gstCharges": 698.64,
  "totalCreditLimit": 193000.00,
  "availableCreditLimit": 80062.00,
  "availableCashLimit": 0.00,
  "detectedSignatures": ["HDFC", "RuPay"]
}
''';

      final resText = await LlmClassifier.queryActiveLlm(prompt);
      if (resText != null && resText.isNotEmpty) {
        final cleanJson =
            resText.replaceAll(RegExp(r'```json|```'), '').trim();
        final dynamic decoded = jsonDecode(cleanJson);
        if (decoded is Map<String, dynamic>) {
          final summary = CreditCardStatementSummary(
            cardName: decoded["bankOrCardName"]?.toString(),
            cardLast4: decoded["cardLast4"]?.toString(),
            statementDate: decoded["statementDate"] != null
                ? DateTime.tryParse(decoded["statementDate"].toString())
                : null,
            dueDate: decoded["dueDate"] != null
                ? DateTime.tryParse(decoded["dueDate"].toString())
                : null,
            billingPeriod: decoded["billingPeriod"]?.toString(),
            totalAmountDue:
                (decoded["totalAmountDue"] as num?)?.toDouble(),
            minAmountDue: (decoded["minAmountDue"] as num?)?.toDouble(),
            previousStatementDue:
                (decoded["previousStatementDue"] as num?)?.toDouble(),
            paymentsReceived:
                (decoded["paymentsReceived"] as num?)?.toDouble(),
            purchasesCurrentCycle:
                (decoded["purchasesCurrentCycle"] as num?)?.toDouble(),
            financeCharges: (decoded["financeCharges"] as num?)?.toDouble(),
            gstCharges: (decoded["gstCharges"] as num?)?.toDouble(),
            totalCreditLimit:
                (decoded["totalCreditLimit"] as num?)?.toDouble(),
            availableCreditLimit:
                (decoded["availableCreditLimit"] as num?)?.toDouble(),
            availableCashLimit:
                (decoded["availableCashLimit"] as num?)?.toDouble(),
            extractedVia: "llm:learned_template",
          );

          // Save learned template for this bank/card type
          final cardName = decoded["bankOrCardName"]?.toString() ?? "Card";
          final cleanId = cardName
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
          final List<String> sigs = (decoded["detectedSignatures"] is List)
              ? (decoded["detectedSignatures"] as List)
                  .map((e) => e.toString())
                  .toList()
              : [cardName.split(' ').first];

          final learnedTemplate = StatementTemplate(
            id: "learned_$cleanId",
            name: cardName,
            signatures: sigs,
            regexTotalDue:
                r'TOTAL\s*AMOUNT\s*DUE\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
            regexMinDue:
                r'MINIMUM\s*(?:AMOUNT\s*)?DUES?\s*[C₹Rs\.INR]*\s*([0-9,]+(?:\.[0-9]{2})?)',
            regexDueDate:
                r'DUE\s*DATE\s*[:\-]?\s*([0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}|[0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4})',
            regexStatementDate:
                r'([0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4})\s*(?:[0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}\s*-\s*[0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4})',
            regexBillingPeriod:
                r'([0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}\s*-\s*[0-3]?[0-9]\s+[A-Za-z]{3},?\s+[0-9]{4}|[0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4}\s*(?:to|-)\s*[0-3]?[0-9][\/\-.][0-1]?[0-9][\/\-.][0-9]{2,4})',
            regexCardNumber: r'([0-9]{4,6}[X*]{4,10}[0-9]{4})',
            isBuiltIn: false,
          );

          await saveLearnedTemplate(learnedTemplate);
          return summary;
        }
      }
    } catch (e) {
      debugPrint("LLM statement summary extraction error: $e");
    }
    return null;
  }
}
