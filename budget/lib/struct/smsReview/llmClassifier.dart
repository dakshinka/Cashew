import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsReview/smsParser.dart';

class LlmClassificationResult {
  final bool isTransaction;
  final String transactionType; // "debit", "credit", "advertisement", "balance_inquiry", "otp", "information", "bill_reminder", "other"
  final double amount;
  final String currency;
  final bool isReminder;
  final String merchant;
  final String category;
  final DateTime? date;
  final String? accountHint;
  final double confidence;
  final String? reasoning;

  LlmClassificationResult({
    required this.isTransaction,
    required this.transactionType,
    required this.amount,
    this.currency = "₹",
    this.isReminder = false,
    required this.merchant,
    required this.category,
    this.date,
    this.accountHint,
    this.confidence = 0.95,
    this.reasoning,
  });
}

class LlmClassifier {
  static const String defaultSystemPrompt = '''
You are an expert financial transaction classification assistant for personal banking and SMS parsing.
Analyze whether the SMS or notification text is an ACTUAL completed financial transaction (money spent, debited, or credited/received), or if it is an advertisement, loan offer, account balance inquiry, informational alert, bill reminder, or OTP.

CLASSIFICATION RULES:
1. "advertisement": Credit card offers, loan pre-approvals, discount promos, cashback banners, marketing ("Pre-approved personal loan", "Get Rs 500 off", "Apply now"). isTransaction MUST be false.
2. "balance_inquiry": Messages that ONLY state the current or available balance without a new debit or credit ("Available balance in A/c is Rs 4500", "Clear balance as on..."). isTransaction MUST be false.
3. "otp": One-time passwords, login security alerts. isTransaction MUST be false.
4. "information": Non-transaction banking alerts, future mandates, or scheduled notices (e.g. "E-Mandate! Rs... will be deducted on...", "will be debited on...", KYC update, daily limit notice, mandate created, cheque book dispatch). isTransaction MUST be false.
5. "bill_reminder": Due date reminders or upcoming bill alerts ("Reminder: Bill of Rs... is due on...", "Payment due for your card"). Set isTransaction to true ONLY so the user can verify if they paid it; set isReminder to true.
6. "debit": Money ALREADY completed, debited, spent, paid, sent, withdrawn, or transferred from user's account/card. Past-tense indicators like "spent", "sent", "debited", "paid" signify actual completed expenses. If it says "will be deducted" or "will be debited", it is an informational future mandate, NOT a debit (isTransaction MUST be false).
7. "credit": Money actually credited, deposited, refunded, or received into user's account. isTransaction MUST be true.

ENTITY EXTRACTION:
- merchant: The genuine shop, vendor, or recipient (e.g. "Raja Enterprises", "Swiggy", "Amazon", "Bharti Airtel"). Clean up UPI handles like @okaxis. If it is a utility or recharge (e.g. "BHARTI AIRTEL LTD"), the merchant is "Bharti Airtel", NEVER the bank!
- category: One of "Food & Dining", "Groceries", "Transportation", "Shopping", "Entertainment", "Health & Medical", "Utilities & Bills", "Income & Salary", "Online Transfer", "Other". (For commercial stores, enterprises, traders, vendor payouts, or bank transfers, classify as "Online Transfer" or "Shopping").
- currency: Currency symbol or code (e.g. "INR", "USD", "EUR", "₹", "\$"). For Indian banks (HDFC, SBI, ICICI, Axis, PNB, Kotak, etc.) and UPI, MUST be "INR" or "₹".
- amount: The FULL EXACT numeric amount transacted. CRITICAL: Capture full thousands/lakhs without truncation (e.g. "4500.00" must be 4500.00, NOT 450; "1000.00" must be 1000.00; "1,50,000.00" must be 150000.00). Never extract the remaining balance number.
- isReminder: boolean (true if this is a bill reminder or upcoming payment due notice).
- date: ISO 8601 date (YYYY-MM-DDTHH:MM:SS) if a date/time is mentioned in the SMS, otherwise null.
- accountHint: The payment source account/card extracted from the "on / from / using / via" clause (e.g. in "spent at BHARTI AIRTEL LTD on RBL Bank credit card (9547)", the merchant is "Bharti Airtel" and the account is "RBL Credit Card *9547", NEVER Airtel!). Include the bank name and account/card number (e.g. *4340 or *9547). CRITICAL: NEVER confuse the merchant with the account name, and NEVER put the transaction amount into accountHint.

Output ONLY valid JSON matching this schema:
{
  "isTransaction": boolean,
  "transactionType": "debit" | "credit" | "advertisement" | "balance_inquiry" | "otp" | "information" | "bill_reminder" | "other",
  "amount": number,
  "currency": string,
  "isReminder": boolean,
  "merchant": string,
  "category": string,
  "date": string or null,
  "accountHint": string or null,
  "confidence": number,
  "reasoning": string
}
''';

  /// Returns the active prompt: either custom user prompt from settings or defaultSystemPrompt
  static String getSystemPrompt() {
    final custom = appStateSettings["customAiPrompt"]?.toString().trim();
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return defaultSystemPrompt;
  }

  /// Save user-customized prompt
  static Future<void> saveSystemPrompt(String prompt) async {
    await updateSettings("customAiPrompt", prompt.trim(), updateGlobalState: true);
  }

  /// Reset to default prompt
  static Future<void> resetSystemPrompt() async {
    await updateSettings("customAiPrompt", "", updateGlobalState: true);
  }

  /// Classify using configured AI model (Gemini free, local Ollama, or edge fallback)
  static Future<LlmClassificationResult?> classify(String rawMessage) async {
    // 0. Pre-filter informational notices, e-mandates, or non-transactions
    if (SmsParser.isInformationalOrFutureNotice(rawMessage)) {
      return LlmClassificationResult(
        isTransaction: false,
        transactionType: "information",
        amount: 0,
        currency: "₹",
        merchant: "",
        category: "Other",
      );
    }

    final provider = appStateSettings["aiProvider"]?.toString() ?? "none";

    if (provider == "gemini") {
      final key = appStateSettings["geminiApiKey"]?.toString().trim();
      if (key != null && key.isNotEmpty) {
        try {
          return await _classifyWithGemini(rawMessage, key);
        } catch (_) {}
      }
    } else if (provider == "ollama") {
      final endpoint = appStateSettings["ollamaEndpoint"]?.toString().trim() ??
          "http://localhost:11434";
      final model = appStateSettings["ollamaModel"]?.toString().trim() ??
          "llama3.2";
      try {
        return await _classifyWithOllama(rawMessage, endpoint, model);
      } catch (_) {}
    }

    // Default: use the enhanced deterministic edge rule parser
    return _classifyWithEdgeRules(rawMessage);
  }

  /// Google Gemini 1.5 Flash (Free Tier)
  static Future<LlmClassificationResult?> _classifyWithGemini(
      String rawMessage, String apiKey) async {
    final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey");

    final response = await http
        .post(
          url,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "contents": [
              {
                "parts": [
                  {
                    "text": "${getSystemPrompt()}\n\nSMS TO CLASSIFY:\n\"\"\"$rawMessage\"\"\""
                  }
                ]
              }
            ],
            "generationConfig": {
              "temperature": 0.1,
              "responseMimeType": "application/json",
            }
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final jsonBody = jsonDecode(response.body);
      final text = jsonBody["candidates"]?[0]?["content"]?["parts"]?[0]?["text"];
      if (text != null) {
        return _parseJsonResponse(text, rawMessage: rawMessage);
      }
    }
    return null;
  }

  /// Local Open-Source Ollama (Llama 3.2, Gemma 2, Qwen 2.5)
  static Future<LlmClassificationResult?> _classifyWithOllama(
      String rawMessage, String endpoint, String model) async {
    final baseUri = endpoint.endsWith("/")
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    final url = Uri.parse("$baseUri/api/generate");

    final response = await http
        .post(
          url,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "model": model,
            "prompt": "${getSystemPrompt()}\n\nSMS TO CLASSIFY:\n\"\"\"$rawMessage\"\"\"",
            "stream": false,
            "format": "json",
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      final jsonBody = jsonDecode(response.body);
      final responseText = jsonBody["response"];
      if (responseText != null) {
        return _parseJsonResponse(responseText, rawMessage: rawMessage);
      }
    }
    return null;
  }

  /// Parses JSON output from either Gemini or Ollama
  static LlmClassificationResult? _parseJsonResponse(String jsonString,
      {String? rawMessage}) {
    try {
      String clean = jsonString.trim();
      if (clean.startsWith("```json")) {
        clean = clean.substring(7);
      }
      if (clean.endsWith("```")) {
        clean = clean.substring(0, clean.length - 3);
      }
      clean = clean.trim();

      final data = jsonDecode(clean);
      final isTxn = data["isTransaction"] == true;
      final type = data["transactionType"]?.toString() ?? "other";
      final amount = (data["amount"] is num)
          ? (data["amount"] as num).toDouble()
          : (double.tryParse(data["amount"]?.toString() ?? "0") ?? 0.0);
      final merchant = data["merchant"]?.toString() ?? "";
      final category = data["category"]?.toString() ?? "Other";
      String? accountHint = data["accountHint"]?.toString().trim();
      final regexHint = (rawMessage != null)
          ? SmsParser.extractAccountHint(rawMessage, amount: amount)
          : null;
      if (regexHint != null && regexHint.isNotEmpty) {
        accountHint = regexHint;
      }

      final confidence = (data["confidence"] is num)
          ? (data["confidence"] as num).toDouble()
          : 0.95;
      final reasoning = data["reasoning"]?.toString();

      DateTime? parsedDate;
      if (data["date"] != null && data["date"].toString().isNotEmpty) {
        parsedDate = DateTime.tryParse(data["date"].toString());
      }

      final isReminder = (data["isReminder"] == true) || (type == "bill_reminder");
      final currency = data["currency"]?.toString() ?? "₹";

      return LlmClassificationResult(
        isTransaction: isTxn && amount > 0,
        transactionType: type,
        amount: amount,
        currency: currency,
        isReminder: isReminder,
        merchant: merchant,
        category: category,
        date: parsedDate,
        accountHint: accountHint,
        confidence: confidence,
        reasoning: reasoning,
      );
    } catch (_) {
      return null;
    }
  }

  /// Edge rule fallback with strict anti-spam & anti-balance filters
  static LlmClassificationResult? _classifyWithEdgeRules(String rawMessage) {
    final parsed = SmsParser.parse(rawMessage);
    if (!parsed.success || parsed.amount <= 0) {
      return LlmClassificationResult(
        isTransaction: false,
        transactionType: "advertisement_or_balance",
        amount: 0,
        currency: "₹",
        merchant: "",
        category: "Other",
      );
    }

    return LlmClassificationResult(
      isTransaction: true,
      transactionType: parsed.isIncome ? "credit" : "debit",
      amount: parsed.amount,
      currency: parsed.currency,
      isReminder: parsed.isReminder,
      merchant: parsed.rawMerchant,
      category: "Other",
      date: parsed.date,
      accountHint: parsed.accountHint,
      confidence: 0.85,
    );
  }
}
