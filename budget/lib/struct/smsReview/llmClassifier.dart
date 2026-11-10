import 'dart:convert';
import 'package:flutter/foundation.dart';
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
  final String? providerUsed;

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
    this.providerUsed,
  });
}

class LlmClassifier {
  /// Stores the most recent diagnostic error message from any AI provider attempt
  static String? lastAiError;
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
7. "credit": Money actually credited, deposited, refunded, or received into user's account. This explicitly INCLUDES messages starting with "Update!" or containing "deposited in ... A/c", "credited", "FT-", "Salary", "Salary Advance", or employer transfers. Boilerplate disclaimers like "Cheque deposits in A/C are subject to clearing" do NOT make it informational when money has been deposited/transferred. isTransaction MUST be true.

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

  /// Returns the active prompt: combines user-customized prompt with learned rules & examples
  static String getSystemPrompt() {
    final customRules = appStateSettings["customAiRules"]?.toString().trim();
    String basePrompt = defaultSystemPrompt;
    final custom = appStateSettings["customAiPrompt"]?.toString().trim();
    if (custom != null && custom.isNotEmpty) {
      basePrompt = custom;
    }
    if (customRules != null && customRules.isNotEmpty) {
      return "$basePrompt\n\nUSER-LEARNED CLASSIFICATION RULES & FEW-SHOT EXAMPLES:\n$customRules";
    }
    return basePrompt;
  }

  /// Teaches the AI about a missed transaction by analyzing it and generating a persistent rule
  static Future<String> teachMissedTransaction(String rawMessage, {String? userFeedback}) async {
    final provider = appStateSettings["aiProvider"]?.toString() ?? "none";
    final key = appStateSettings["geminiApiKey"]?.toString().trim();

    String learnedRule = "- Example: \"\"\"$rawMessage\"\"\" -> isTransaction: true. Even if starting with 'Update!' or containing remarks like 'subject to clearing', recognize the credit/deposit.";

    final geminiModel = appStateSettings["geminiModel"]?.toString().trim() ?? "gemini-1.5-flash";

    if (provider == "gemini" && key != null && key.isNotEmpty) {
      try {
        final url = Uri.parse(
            "https://generativelanguage.googleapis.com/v1beta/models/$geminiModel:generateContent?key=$key");
        final prompt = '''
You are an expert financial classification assistant.
The user flagged this SMS as a REAL financial transaction that was previously missed or misclassified:
"""$rawMessage"""
${userFeedback != null && userFeedback.isNotEmpty ? "User feedback: $userFeedback" : ""}

Generate a concise 1-2 sentence learning rule and few-shot example for why this is a transaction, how to extract the amount/merchant/account, and what keywords to check.
Output ONLY the rule text to append to the system prompt.
''';
        final response = await http.post(
          url,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "contents": [
              {
                "parts": [{"text": prompt}]
              }
            ],
            "generationConfig": {"temperature": 0.2}
          }),
        );
        if (response.statusCode == 200) {
          final resData = jsonDecode(response.body);
          final candidates = resData["candidates"] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final text = candidates[0]["content"]["parts"][0]["text"]?.toString().trim();
            if (text != null && text.isNotEmpty) {
              learnedRule = text;
            }
          }
        }
      } catch (_) {}
    } else if ((provider == "groq" || provider == "openrouter")) {
      final apiKey = provider == "groq"
          ? appStateSettings["groqApiKey"]?.toString().trim()
          : appStateSettings["openRouterApiKey"]?.toString().trim();
      final urlStr = provider == "groq"
          ? "https://api.groq.com/openai/v1/chat/completions"
          : "https://openrouter.ai/api/v1/chat/completions";
      final model = provider == "groq"
          ? (appStateSettings["groqModel"]?.toString().trim() ?? "llama-3.3-70b-versatile")
          : (appStateSettings["openRouterModel"]?.toString().trim() ?? "meta-llama/llama-3.3-70b-instruct:free");

      if (apiKey != null && apiKey.isNotEmpty) {
        try {
          final response = await http.post(
            Uri.parse(urlStr),
            headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer $apiKey",
            },
            body: jsonEncode({
              "model": model,
              "messages": [
                {
                  "role": "user",
                  "content": "The user flagged this SMS as a REAL financial transaction that was previously missed or misclassified:\n\"\"\"$rawMessage\"\"\"\n\nGenerate a concise 1-2 sentence learning rule and few-shot example for why this is a transaction, how to extract the amount/merchant/account, and what keywords to check. Output ONLY the rule text to append to system prompt."
                }
              ],
              "temperature": 0.2,
            }),
          );
          if (response.statusCode == 200) {
            final resData = jsonDecode(response.body);
            final text = resData["choices"]?[0]?["message"]?["content"]?.toString().trim();
            if (text != null && text.isNotEmpty) {
              learnedRule = text;
            }
          }
        } catch (_) {}
      }
    }

    final existingRules = appStateSettings["customAiRules"]?.toString().trim() ?? "";
    final updatedRules = existingRules.isEmpty ? learnedRule : "$existingRules\n\n$learnedRule";
    await updateSettings("customAiRules", updatedRules, updateGlobalState: true);
    return learnedRule;
  }

  /// Save user-customized prompt
  static Future<void> saveSystemPrompt(String prompt) async {
    await updateSettings("customAiPrompt", prompt.trim(), updateGlobalState: true);
  }

  /// Reset to default prompt
  static Future<void> resetSystemPrompt() async {
    await updateSettings("customAiPrompt", "", updateGlobalState: true);
  }

  /// Single provider execution helper
  static Future<LlmClassificationResult?> _tryClassify(
      String provider, String rawMessage) async {
    try {
      if (provider == "gemini") {
        final key = appStateSettings["geminiApiKey"]?.toString().trim();
        final model = appStateSettings["geminiModel"]?.toString().trim();
        if (key != null && key.isNotEmpty) {
          return await _classifyWithGemini(rawMessage, key, model: model);
        } else {
          lastAiError = "Gemini API key is missing. Tap the brain icon in Review Inbox to paste your key.";
        }
      } else if (provider == "groq") {
        final key = appStateSettings["groqApiKey"]?.toString().trim();
        final model = appStateSettings["groqModel"]?.toString().trim();
        if (key != null && key.isNotEmpty) {
          return await _classifyWithGroq(rawMessage, key, model: model);
        } else {
          lastAiError = "Groq API key is missing. Tap the brain icon in Review Inbox to paste your key.";
        }
      } else if (provider == "openrouter") {
        final key = appStateSettings["openRouterApiKey"]?.toString().trim();
        final model = appStateSettings["openRouterModel"]?.toString().trim();
        if (key != null && key.isNotEmpty) {
          return await _classifyWithOpenRouter(rawMessage, key, model: model);
        } else {
          lastAiError = "OpenRouter API key is missing. Tap the brain icon in Review Inbox to paste your key.";
        }
      } else if (provider == "ollama") {
        final endpoint =
            appStateSettings["ollamaEndpoint"]?.toString().trim() ??
                "http://localhost:11434";
        final model = appStateSettings["ollamaModel"]?.toString().trim() ??
            "llama3.2";
        return await _classifyWithOllama(rawMessage, endpoint, model);
      }
    } catch (e) {
      if (provider == "ollama" && e.toString().contains("Connection refused")) {
        lastAiError =
            "Ollama connection refused. If running on PC, use your PC's Wi-Fi IP (not 'localhost') and ensure Ollama was started with OLLAMA_HOST=0.0.0.0:11434.";
      } else {
        lastAiError = "$provider connection error: $e";
      }
      debugPrint("Provider $provider classification error: $e");
    }
    return null;
  }

  /// Classify using configured AI model with automatic multi-provider failover
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

    final primaryProvider =
        appStateSettings["aiProvider"]?.toString() ?? "none";

    // 1. Try primary provider first (if not "none")
    if (primaryProvider != "none") {
      final res = await _tryClassify(primaryProvider, rawMessage);
      if (res != null) return res;
    }

    // 2. Automatic Failover: Try other providers if configured
    const allProviders = ["groq", "gemini", "openrouter", "ollama"];
    for (final p in allProviders) {
      if (p == primaryProvider) continue;
      bool hasCredentials = false;
      if (p == "groq") {
        hasCredentials =
            (appStateSettings["groqApiKey"]?.toString().trim().isNotEmpty ??
                false);
      } else if (p == "gemini") {
        hasCredentials =
            (appStateSettings["geminiApiKey"]?.toString().trim().isNotEmpty ??
                false);
      } else if (p == "openrouter") {
        hasCredentials = (appStateSettings["openRouterApiKey"]
                ?.toString()
                .trim()
                .isNotEmpty ??
            false);
      } else if (p == "ollama") {
        hasCredentials = (appStateSettings["ollamaEndpoint"]
                ?.toString()
                .trim()
                .isNotEmpty ??
            false);
      }

      if (hasCredentials) {
        final failoverRes = await _tryClassify(p, rawMessage);
        if (failoverRes != null) {
          debugPrint("⚡ Fallback succeeded with provider: $p");
          return failoverRes;
        }
      }
    }

    // 3. Final Default: 100% offline edge rule parser
    return _classifyWithEdgeRules(rawMessage);
  }

  /// Lists available models for this Gemini API key that support generateContent
  static Future<List<String>> _listGeminiModels(String apiKey) async {
    final candList = <String>[];
    for (final apiVersion in ["v1beta", "v1"]) {
      try {
        final url = Uri.parse(
            "https://generativelanguage.googleapis.com/$apiVersion/models?key=$apiKey");
        final resp = await http.get(url).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final models = data["models"] as List?;
          if (models != null) {
            for (final m in models) {
              final name = m["name"]?.toString() ?? "";
              final methods = (m["supportedGenerationMethods"] as List?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  [];
              if (methods.contains("generateContent")) {
                candList.add(name.replaceFirst("models/", ""));
              }
            }
          }
        }
        if (candList.isNotEmpty) break;
      } catch (_) {}
    }
    return candList;
  }

  /// Google Gemini (Customizable model with automatic v1/v1beta fallback & model discovery)
  static Future<LlmClassificationResult?> _classifyWithGemini(
      String rawMessage, String apiKey, {String? model}) async {
    final requestedModel = (model != null && model.isNotEmpty)
        ? model
        : (appStateSettings["geminiModel"]?.toString().trim().isNotEmpty == true
            ? appStateSettings["geminiModel"]!.toString().trim()
            : "gemini-1.5-flash");

    // Try candidate models: requested model first, then common aliases
    final candidateModels = [
      requestedModel,
      if (requestedModel != "gemini-1.5-flash-latest") "gemini-1.5-flash-latest",
      if (requestedModel != "gemini-2.0-flash-exp") "gemini-2.0-flash-exp",
      if (requestedModel != "gemini-1.5-flash") "gemini-1.5-flash",
      if (requestedModel != "gemini-1.5-pro") "gemini-1.5-pro",
    ];

    for (final candidate in candidateModels) {
      for (final apiVersion in ["v1beta", "v1"]) {
        final url = Uri.parse(
            "https://generativelanguage.googleapis.com/$apiVersion/models/$candidate:generateContent?key=$apiKey");

        final bodyMap = <String, dynamic>{
          "contents": [
            {
              "parts": [
                {
                  "text":
                      "${getSystemPrompt()}\n\nSMS TO CLASSIFY:\n\"\"\"$rawMessage\"\"\""
                }
              ]
            }
          ],
          "generationConfig": {
            "temperature": 0.1,
            if (apiVersion == "v1beta") "responseMimeType": "application/json",
          }
        };

        try {
          final response = await http
              .post(
                url,
                headers: {"Content-Type": "application/json"},
                body: jsonEncode(bodyMap),
              )
              .timeout(const Duration(seconds: 12));

          if (response.statusCode == 200) {
            final jsonBody = jsonDecode(response.body);
            final text = jsonBody["candidates"]?[0]?["content"]?["parts"]?[0]?["text"];
            if (text != null) {
              lastAiError = null;
              if (candidate != requestedModel) {
                await updateSettings("geminiModel", candidate,
                    updateGlobalState: false);
              }
              return _parseJsonResponse(text,
                  rawMessage: rawMessage, provider: "Gemini ($candidate)");
            }
          } else if (response.statusCode == 404) {
            // Model not supported on this version, try next version or candidate
            continue;
          } else {
            String detail = "Gemini HTTP ${response.statusCode}";
            try {
              final errJson = jsonDecode(response.body);
              final msg = errJson["error"]?["message"];
              if (msg != null) detail = "Gemini: $msg";
            } catch (_) {
              detail = "Gemini HTTP ${response.statusCode}: ${response.body}";
            }
            lastAiError = detail;
            debugPrint("Gemini classification failed: $detail");
            return null;
          }
        } catch (e) {
          debugPrint("Gemini attempt error for $candidate ($apiVersion): $e");
        }
      }
    }

    // If all candidate attempts failed, query the user's available model list
    try {
      final available = await _listGeminiModels(apiKey);
      if (available.isNotEmpty) {
        lastAiError =
            "Model '$requestedModel' not found. Available models for your API key: ${available.take(4).join(', ')}. Please select one in AI Settings.";
      } else {
        lastAiError =
            "Gemini API key is invalid or Generative Language API is not enabled in your Google Cloud / AI Studio project.";
      }
    } catch (_) {
      lastAiError =
          "Gemini: models/$requestedModel not found or not supported for generateContent.";
    }
    return null;
  }

  /// Groq (Ultra-Fast Cloud Llama 3.3 / Llama 3.1)
  static Future<LlmClassificationResult?> _classifyWithGroq(
      String rawMessage, String apiKey, {String? model}) async {
    final url = Uri.parse("https://api.groq.com/openai/v1/chat/completions");
    final activeModel = (model != null && model.isNotEmpty)
        ? model
        : "llama-3.3-70b-versatile";

    final response = await http
        .post(
          url,
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer $apiKey",
          },
          body: jsonEncode({
            "model": activeModel,
            "messages": [
              {"role": "system", "content": getSystemPrompt()},
              {
                "role": "user",
                "content": "SMS TO CLASSIFY:\n\"\"\"$rawMessage\"\"\""
              }
            ],
            "response_format": {"type": "json_object"},
            "temperature": 0.1,
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final jsonBody = jsonDecode(response.body);
      final text = jsonBody["choices"]?[0]?["message"]?["content"];
      if (text != null) {
        lastAiError = null;
        return _parseJsonResponse(text,
            rawMessage: rawMessage, provider: "Groq ($activeModel)");
      }
    } else {
      String detail = "Groq HTTP ${response.statusCode}";
      try {
        final errJson = jsonDecode(response.body);
        final msg = errJson["error"]?["message"];
        if (msg != null) detail = "Groq: $msg";
      } catch (_) {
        detail = "Groq HTTP ${response.statusCode}: ${response.body}";
      }
      lastAiError = detail;
      debugPrint("Groq classification failed: $detail");
    }
    return null;
  }

  /// OpenRouter (Any Cloud Model - Llama 3.3, Gemini 2.0 Flash, Mistral, Claude)
  static Future<LlmClassificationResult?> _classifyWithOpenRouter(
      String rawMessage, String apiKey, {String? model}) async {
    final url = Uri.parse("https://openrouter.ai/api/v1/chat/completions");
    final activeModel = (model != null && model.isNotEmpty)
        ? model
        : "meta-llama/llama-3.3-70b-instruct:free";

    final response = await http
        .post(
          url,
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer $apiKey",
            "HTTP-Referer": "https://cashewapp.web.app",
            "X-Title": "Cashew Budget Review",
          },
          body: jsonEncode({
            "model": activeModel,
            "messages": [
              {"role": "system", "content": getSystemPrompt()},
              {
                "role": "user",
                "content": "SMS TO CLASSIFY:\n\"\"\"$rawMessage\"\"\""
              }
            ],
            "response_format": {"type": "json_object"},
            "temperature": 0.1,
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode == 200) {
      final jsonBody = jsonDecode(response.body);
      final text = jsonBody["choices"]?[0]?["message"]?["content"];
      if (text != null) {
        lastAiError = null;
        return _parseJsonResponse(text,
            rawMessage: rawMessage, provider: "OpenRouter ($activeModel)");
      }
    } else {
      String detail = "OpenRouter HTTP ${response.statusCode}";
      try {
        final errJson = jsonDecode(response.body);
        final msg = errJson["error"]?["message"];
        if (msg != null) detail = "OpenRouter: $msg";
      } catch (_) {
        detail = "OpenRouter HTTP ${response.statusCode}: ${response.body}";
      }
      lastAiError = detail;
      debugPrint("OpenRouter classification failed: $detail");
    }
    return null;
  }

  /// Local Open-Source Ollama (Llama 3.2, Gemma 2, Qwen 2.5)
  static Future<LlmClassificationResult?> _classifyWithOllama(
      String rawMessage, String endpoint, String model) async {
    if (endpoint.contains("localhost") || endpoint.contains("127.0.0.1")) {
      lastAiError =
          "Ollama: 'localhost' cannot be reached from an Android phone. Use your computer's local Wi-Fi IP (e.g. http://192.168.1.X:11434) and launch Ollama with OLLAMA_HOST=0.0.0.0:11434.";
      debugPrint("Ollama classification skipped: $lastAiError");
      return null;
    }

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
        lastAiError = null;
        return _parseJsonResponse(responseText,
            rawMessage: rawMessage, provider: "Ollama ($model)");
      }
    } else {
      lastAiError = "Ollama HTTP ${response.statusCode}: ${response.body}";
    }
    return null;
  }

  /// Parses JSON output from either Gemini, Groq, OpenRouter or Ollama
  static LlmClassificationResult? _parseJsonResponse(String jsonString,
      {String? rawMessage, String? provider}) {
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
        providerUsed: provider,
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
        providerUsed: "Built-in Edge Rules (Offline)",
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
      providerUsed: "Built-in Edge Rules (Offline)",
    );
  }
}
