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

  /// Queries active LLM provider directly with a custom prompt
  static Future<String?> queryActiveLlm(String prompt) async {
    final provider = appStateSettings["aiProvider"]?.toString() ?? "none";
    if (provider == "none") return null;

    if (provider == "groq") {
      final key = appStateSettings["groqApiKey"]?.toString().trim() ?? "";
      if (key.isNotEmpty) {
        final model = appStateSettings["groqModel"]?.toString().trim() ??
            "llama-3.3-70b-versatile";
        try {
          final resp = await http
              .post(
                Uri.parse("https://api.groq.com/openai/v1/chat/completions"),
                headers: {
                  "Content-Type": "application/json",
                  "Authorization": "Bearer $key"
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {"role": "user", "content": prompt}
                  ],
                  "temperature": 0.1,
                }),
              )
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            return data["choices"]?[0]?["message"]?["content"];
          }
        } catch (_) {}
      }
    } else if (provider == "gemini") {
      final key = appStateSettings["geminiApiKey"]?.toString().trim() ?? "";
      if (key.isNotEmpty) {
        final model = appStateSettings["geminiModel"]?.toString().trim() ??
            "gemini-flash-latest";
        try {
          final resp = await http
              .post(
                Uri.parse(
                    "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
                headers: {
                  "Content-Type": "application/json",
                  "Authorization": "Bearer $key",
                  "x-goog-api-key": key,
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {"role": "user", "content": prompt}
                  ],
                  "temperature": 0.1,
                }),
              )
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            return data["choices"]?[0]?["message"]?["content"];
          }
        } catch (_) {}
      }
    } else if (provider == "openrouter") {
      final key =
          appStateSettings["openRouterApiKey"]?.toString().trim() ?? "";
      if (key.isNotEmpty) {
        final model = appStateSettings["openRouterModel"]?.toString().trim() ??
            "meta-llama/llama-3.3-70b-instruct:free";
        try {
          final resp = await http
              .post(
                Uri.parse("https://openrouter.ai/api/v1/chat/completions"),
                headers: {
                  "Content-Type": "application/json",
                  "Authorization": "Bearer $key"
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {"role": "user", "content": prompt}
                  ],
                  "temperature": 0.1,
                }),
              )
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            return data["choices"]?[0]?["message"]?["content"];
          }
        } catch (_) {}
      }
    } else if (provider == "ollama") {
      final ep = appStateSettings["ollamaEndpoint"]?.toString().trim() ??
          "http://192.168.1.100:11434";
      final model =
          appStateSettings["ollamaModel"]?.toString().trim() ?? "llama3.2";
      if (!ep.contains("localhost")) {
        try {
          final base = ep.endsWith("/") ? ep.substring(0, ep.length - 1) : ep;
          final resp = await http
              .post(
                Uri.parse("$base/api/generate"),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({
                  "model": model,
                  "prompt": prompt,
                  "stream": false
                }),
              )
              .timeout(const Duration(seconds: 15));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            return data["response"];
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// Synthesizes an offline regex pattern from an SMS that required AI classification,
  /// storing it locally so all future messages of this bank format run 100% offline at 0 AI cost.
  static Future<bool> synthesizeAndStoreRegexPattern(
      String rawMessage, LlmClassificationResult result) async {
    if (!result.isTransaction || result.amount <= 0) return false;

    try {
      final prompt = '''
You are a regex synthesis assistant.
A banking SMS was not matched by default edge rules:
"""$rawMessage"""

Extracted values:
- Amount: ${result.amount}
- Merchant: ${result.merchant}
- Is Income: ${result.transactionType == 'credit'}

Create a generalized Dart RegExp pattern (case-insensitive) to extract the amount and merchant from similar future messages.
Output strictly JSON:
{
  "pattern": "regex_pattern_string_here",
  "amountGroup": 1,
  "merchantGroup": 2,
  "isIncome": ${result.transactionType == 'credit'}
}
''';

      final responseText = await queryActiveLlm(prompt);
      if (responseText != null && responseText.isNotEmpty) {
        final cleanJson =
            responseText.replaceAll(RegExp(r'```json|```'), '').trim();
        final Map<String, dynamic> data = jsonDecode(cleanJson);
        final pattern = data["pattern"]?.toString();
        final amountGroup =
            data["amountGroup"] is int ? data["amountGroup"] as int : 1;
        final merchantGroup =
            data["merchantGroup"] is int ? data["merchantGroup"] as int : null;
        final isIncome = data["isIncome"] == true;

        if (pattern != null && pattern.isNotEmpty) {
          final reg = RegExp(pattern, caseSensitive: false);
          final match = reg.firstMatch(rawMessage);
          if (match != null) {
            await SmsParser.addLearnedPattern(
              pattern: pattern,
              amountGroup: amountGroup,
              merchantGroup: merchantGroup,
              isIncome: isIncome,
              exampleSms: rawMessage,
            );
            debugPrint("Synthesized & stored offline regex: $pattern");
            return true;
          }
        }
      }
    } catch (e) {
      debugPrint("Regex synthesis error: $e");
    }
    return false;
  }

  /// Save user-customized prompt
  static Future<void> saveSystemPrompt(String prompt) async {
    await updateSettings("customAiPrompt", prompt.trim(), updateGlobalState: true);
  }

  /// Reset to default prompt
  static Future<void> resetSystemPrompt() async {
    await updateSettings("customAiPrompt", "", updateGlobalState: true);
  }

  /// Tests connection with provided AI provider, key, model, or endpoint
  static Future<Map<String, dynamic>> testConnection({
    required String provider,
    String? apiKey,
    String? model,
    String? endpoint,
  }) async {
    final sw = Stopwatch()..start();
    const testSample =
        "INR 250.00 spent at CAFE COFFEE DAY on HDFC Bank Card XX4340 on 10-Nov-2026";

    lastAiError = null;

    try {
      if (provider == "gemini") {
        final key = apiKey?.trim() ?? "";
        if (key.isEmpty) {
          return {
            "success": false,
            "message": "Gemini API key is empty. Please enter your key.",
          };
        }
        final res = await _classifyWithGemini(testSample, key, model: model);
        sw.stop();
        if (res != null) {
          return {
            "success": true,
            "latencyMs": sw.elapsedMilliseconds,
            "provider": res.providerUsed ?? "Gemini",
            "message":
                "Connected to ${res.providerUsed ?? 'Gemini'} in ${sw.elapsedMilliseconds}ms!\nTest parse: extracted ₹${res.amount.toInt()} at '${res.merchant}'.",
          };
        }
        return {
          "success": false,
          "message": lastAiError ??
              "Failed to get response from Gemini. Check model name or key permissions.",
        };
      } else if (provider == "groq") {
        final key = apiKey?.trim() ?? "";
        if (key.isEmpty) {
          return {
            "success": false,
            "message": "Groq API key is empty. Please enter your key (gsk_...).",
          };
        }
        final res = await _classifyWithGroq(testSample, key, model: model);
        sw.stop();
        if (res != null) {
          return {
            "success": true,
            "latencyMs": sw.elapsedMilliseconds,
            "provider": res.providerUsed ?? "Groq",
            "message":
                "Connected to ${res.providerUsed ?? 'Groq'} in ${sw.elapsedMilliseconds}ms!\nTest parse: extracted ₹${res.amount.toInt()} at '${res.merchant}'.",
          };
        }
        return {
          "success": false,
          "message": lastAiError ??
              "Failed to get response from Groq. Verify API key or model.",
        };
      } else if (provider == "openrouter") {
        final key = apiKey?.trim() ?? "";
        if (key.isEmpty) {
          return {
            "success": false,
            "message":
                "OpenRouter API key is empty. Please enter your key (sk-or-...).",
          };
        }
        final res = await _classifyWithOpenRouter(testSample, key, model: model);
        sw.stop();
        if (res != null) {
          return {
            "success": true,
            "latencyMs": sw.elapsedMilliseconds,
            "provider": res.providerUsed ?? "OpenRouter",
            "message":
                "Connected to ${res.providerUsed ?? 'OpenRouter'} in ${sw.elapsedMilliseconds}ms!\nTest parse: extracted ₹${res.amount.toInt()} at '${res.merchant}'.",
          };
        }
        return {
          "success": false,
          "message": lastAiError ??
              "Failed to get response from OpenRouter. Verify model slug or key.",
        };
      } else if (provider == "ollama") {
        final ep = endpoint?.trim() ?? "http://localhost:11434";
        final mdl =
            (model?.trim().isNotEmpty == true) ? model!.trim() : "llama3.2";
        final res = await _classifyWithOllama(testSample, ep, mdl);
        sw.stop();
        if (res != null) {
          return {
            "success": true,
            "latencyMs": sw.elapsedMilliseconds,
            "provider": res.providerUsed ?? "Ollama",
            "message":
                "Connected to Ollama ($mdl) at $ep in ${sw.elapsedMilliseconds}ms!",
          };
        }
        return {
          "success": false,
          "message": lastAiError ??
              "Failed to connect to Ollama at $ep. Check if Ollama is running and accessible over Wi-Fi.",
        };
      } else {
        return {
          "success": true,
          "latencyMs": 0,
          "provider": "Edge Rules",
          "message": "Built-in offline engine is active and ready.",
        };
      }
    } catch (e) {
      sw.stop();
      return {
        "success": false,
        "message": "Connection error: $e",
      };
    }
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

  /// Unified model detection across providers
  static Future<List<Map<String, dynamic>>> listProviderModels({
    required String provider,
    String? apiKey,
    String? endpoint,
  }) async {
    final cleanKey = (apiKey ?? '').trim();
    final cleanEp = (endpoint ?? '').trim();

    if (provider == 'gemini') {
      return listGeminiModels(cleanKey);
    } else if (provider == 'groq') {
      return listGroqModels(cleanKey);
    } else if (provider == 'openrouter') {
      return listOpenRouterModels(cleanKey);
    } else if (provider == 'ollama') {
      return listOllamaModels(cleanEp);
    }
    return [];
  }

  /// Lists available models for this Gemini API key, categorizing free vs paid
  static Future<List<Map<String, dynamic>>> listGeminiModels(
      String apiKey) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) return [];

    final candList = <Map<String, dynamic>>[];
    final seen = <String>{};

    // 1. Try OpenAI-compatible endpoint (identical to StudyVault)
    try {
      final url = Uri.parse(
          "https://generativelanguage.googleapis.com/v1beta/openai/models");
      final resp = await http.get(url, headers: {
        "Authorization": "Bearer $cleanKey",
        "x-goog-api-key": cleanKey,
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final models = (data["data"] ?? data["models"]) as List?;
        if (models != null) {
          for (final m in models) {
            final rawId = m["id"]?.toString() ?? m["name"]?.toString() ?? "";
            final cleanName =
                rawId.replaceFirst(RegExp(r'^models/'), '').trim();
            if (cleanName.isEmpty || seen.contains(cleanName)) continue;
            seen.add(cleanName);
            final lower = cleanName.toLowerCase();
            final isFlash = lower.contains("flash");
            final isExp = lower.contains("-exp") || lower.contains("preview");
            final isFree = isFlash || isExp;
            candList.add({
              "model": cleanName,
              "label": isFree
                  ? "🟢 $cleanName (Free Tier)"
                  : "🟡 $cleanName (Paid / Billing Required)",
              "isFree": isFree,
            });
          }
        }
      }
    } catch (_) {}

    // 2. Try native Google endpoint fallback across API versions
    if (candList.isEmpty) {
      for (final apiVersion in ["v1beta", "v1", "v1alpha"]) {
        try {
          final url = Uri.parse(
              "https://generativelanguage.googleapis.com/$apiVersion/models?key=${Uri.encodeQueryComponent(cleanKey)}");
          final resp = await http.get(url, headers: {
            "x-goog-api-key": cleanKey,
          }).timeout(const Duration(seconds: 8));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            final models = data["models"] as List?;
            if (models != null) {
              for (final m in models) {
                final rawName = m["name"]?.toString() ?? "";
                final cleanName =
                    rawName.replaceFirst(RegExp(r'^models/'), '').trim();
                if (cleanName.isEmpty || seen.contains(cleanName)) continue;
                final methods = (m["supportedGenerationMethods"] as List?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    [];
                if (methods.contains("generateContent")) {
                  seen.add(cleanName);
                  final lower = cleanName.toLowerCase();
                  final isFlash = lower.contains("flash");
                  final isExp =
                      lower.contains("-exp") || lower.contains("preview");
                  final isFree = isFlash || isExp;
                  candList.add({
                    "model": cleanName,
                    "label": isFree
                        ? "🟢 $cleanName (Free Tier)"
                        : "🟡 $cleanName (Paid / Billing Required)",
                    "isFree": isFree,
                  });
                }
              }
            }
          }
          if (candList.isNotEmpty) break;
        } catch (_) {}
      }
    }

    // Sort: Free Flash models first, then Pro models
    candList.sort((a, b) {
      if (a["isFree"] == true && b["isFree"] != true) return -1;
      if (a["isFree"] != true && b["isFree"] == true) return 1;
      final aModel = a["model"] as String;
      final bModel = b["model"] as String;
      if (aModel.contains("flash-latest")) return -1;
      if (bModel.contains("flash-latest")) return 1;
      if (aModel.contains("2.5-flash")) return -1;
      if (bModel.contains("2.5-flash")) return 1;
      return aModel.compareTo(bModel);
    });

    return candList;
  }

  /// Lists available models for Groq
  static Future<List<Map<String, dynamic>>> listGroqModels(
      String apiKey) async {
    final cleanKey = apiKey.trim();
    if (cleanKey.isEmpty) return [];
    try {
      final url = Uri.parse("https://api.groq.com/openai/v1/models");
      final resp = await http.get(url, headers: {
        "Authorization": "Bearer $cleanKey",
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final list = data["data"] as List?;
        if (list != null) {
          final res = <Map<String, dynamic>>[];
          for (final m in list) {
            final id = m["id"]?.toString() ?? "";
            if (id.isEmpty) continue;
            // Filter out audio-only models (whisper) from text classification
            if (id.contains("whisper")) continue;
            res.add({
              "model": id,
              "label": "🟢 $id (Free)",
              "isFree": true,
            });
          }
          res.sort((a, b) {
            final aModel = a["model"] as String;
            final bModel = b["model"] as String;
            if (aModel.contains("llama-3.3-70b")) return -1;
            if (bModel.contains("llama-3.3-70b")) return 1;
            if (aModel.contains("llama-3.1-8b")) return -1;
            if (bModel.contains("llama-3.1-8b")) return 1;
            return aModel.compareTo(bModel);
          });
          return res;
        }
      }
    } catch (e) {
      debugPrint("Groq list models error: $e");
    }
    return [];
  }

  /// Lists available models for OpenRouter
  static Future<List<Map<String, dynamic>>> listOpenRouterModels(
      String apiKey) async {
    try {
      final url = Uri.parse("https://openrouter.ai/api/v1/models");
      final headers = <String, String>{};
      if (apiKey.trim().isNotEmpty) {
        headers["Authorization"] = "Bearer ${apiKey.trim()}";
      }
      final resp = await http
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final list = data["data"] as List?;
        if (list != null) {
          final freeModels = <Map<String, dynamic>>[];
          final paidModels = <Map<String, dynamic>>[];

          for (final m in list) {
            final id = m["id"]?.toString() ?? "";
            if (id.isEmpty) continue;
            final name = m["name"]?.toString() ?? id;
            final isFree = id.endsWith(":free") ||
                (m["pricing"] != null &&
                    (m["pricing"]["prompt"] == 0 ||
                        m["pricing"]["prompt"] == "0"));

            final item = {
              "model": id,
              "label": isFree ? "🟢 $name (Free)" : "🟡 $name (Paid)",
              "isFree": isFree,
            };

            if (isFree) {
              freeModels.add(item);
            } else {
              paidModels.add(item);
            }
          }
          freeModels.sort((a, b) =>
              (a["model"] as String).compareTo(b["model"] as String));
          return [...freeModels, ...paidModels.take(25)];
        }
      }
    } catch (e) {
      debugPrint("OpenRouter list models error: $e");
    }
    return [];
  }

  /// Lists downloaded models on local Ollama instance
  static Future<List<Map<String, dynamic>>> listOllamaModels(
      String endpoint) async {
    final ep = endpoint.trim().isEmpty
        ? "http://192.168.1.100:11434"
        : endpoint.trim();
    if (ep.contains("localhost") || ep.contains("127.0.0.1")) {
      return [];
    }
    final baseUri = ep.endsWith("/") ? ep.substring(0, ep.length - 1) : ep;
    final res = <Map<String, dynamic>>[];
    final seen = <String>{};

    // 1. Try /v1/models (standard OpenAI-compatible in Ollama)
    try {
      final resp = await http
          .get(Uri.parse("$baseUri/v1/models"))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final list = data["data"] as List?;
        if (list != null) {
          for (final m in list) {
            final id = m["id"]?.toString() ?? "";
            if (id.isNotEmpty && !seen.contains(id)) {
              seen.add(id);
              res.add({
                "model": id,
                "label": "🟢 $id (Local)",
                "isFree": true,
              });
            }
          }
        }
      }
    } catch (_) {}

    // 2. Try /api/tags (native Ollama endpoint)
    if (res.isEmpty) {
      try {
        final resp = await http
            .get(Uri.parse("$baseUri/api/tags"))
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final list = data["models"] as List?;
          if (list != null) {
            for (final m in list) {
              final name = m["name"]?.toString() ?? "";
              if (name.isNotEmpty && !seen.contains(name)) {
                seen.add(name);
                res.add({
                  "model": name,
                  "label": "🟢 $name (Local)",
                  "isFree": true,
                });
              }
            }
          }
        }
      } catch (_) {}
    }
    return res;
  }

  /// Google Gemini (Customizable model with automatic OpenAI endpoint & native generateContent fallback)
  static Future<LlmClassificationResult?> _classifyWithGemini(
      String rawMessage, String apiKey, {String? model}) async {
    final cleanApiKey = apiKey.trim();
    final rawRequestedModel = (model != null && model.isNotEmpty)
        ? model.replaceFirst(RegExp(r'^models/'), '').trim()
        : (appStateSettings["geminiModel"]?.toString().trim().isNotEmpty == true
            ? appStateSettings["geminiModel"]!
                .toString()
                .trim()
                .replaceFirst(RegExp(r'^models/'), '')
            : "gemini-flash-latest");

    final requestedModel =
        rawRequestedModel.isEmpty ? "gemini-flash-latest" : rawRequestedModel;

    // Prioritized candidates (following StudyVault preset pattern)
    final candidateModels = [
      requestedModel,
      if (requestedModel != "gemini-flash-latest") "gemini-flash-latest",
      if (requestedModel != "gemini-2.5-flash") "gemini-2.5-flash",
      if (requestedModel != "gemini-flash-lite-latest") "gemini-flash-lite-latest",
      if (requestedModel != "gemini-1.5-flash") "gemini-1.5-flash",
      if (requestedModel != "gemini-2.0-flash-exp") "gemini-2.0-flash-exp",
    ];

    String lastDetail = "";

    for (final candidate in candidateModels) {
      final cleanCand = candidate.replaceFirst(RegExp(r'^models/'), '').trim();

      // Method 1: OpenAI-compatible chat completions (like StudyVault)
      try {
        final openAiUrl = Uri.parse(
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions");
        final openAiResp = await http
            .post(
              openAiUrl,
              headers: {
                "Content-Type": "application/json",
                "Authorization": "Bearer $cleanApiKey",
                "x-goog-api-key": cleanApiKey,
              },
              body: jsonEncode({
                "model": cleanCand,
                "temperature": 0.1,
                "messages": [
                  {"role": "system", "content": getSystemPrompt()},
                  {
                    "role": "user",
                    "content": "SMS TO CLASSIFY:\n\"\"\"$rawMessage\"\"\""
                  }
                ],
                "response_format": {"type": "json_object"},
                "max_tokens": 1024,
              }),
            )
            .timeout(const Duration(seconds: 12));

        if (openAiResp.statusCode == 200) {
          final jsonBody = jsonDecode(openAiResp.body);
          final text = jsonBody["choices"]?[0]?["message"]?["content"];
          if (text != null) {
            lastAiError = null;
            if (cleanCand != requestedModel) {
              await updateSettings("geminiModel", cleanCand,
                  updateGlobalState: false);
            }
            return _parseJsonResponse(text,
                rawMessage: rawMessage, provider: "Gemini ($cleanCand)");
          }
        } else {
          try {
            final errJson = jsonDecode(openAiResp.body);
            lastDetail = errJson["error"]?["message"] ?? openAiResp.body;
          } catch (_) {
            lastDetail = "HTTP ${openAiResp.statusCode}: ${openAiResp.body}";
          }
        }
      } catch (e) {
        lastDetail = e.toString();
      }

      // Method 2: Native Google generateContent fallback
      for (final apiVersion in ["v1beta", "v1", "v1alpha"]) {
        final url = Uri.parse(
            "https://generativelanguage.googleapis.com/$apiVersion/models/$cleanCand:generateContent?key=${Uri.encodeQueryComponent(cleanApiKey)}");

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
                headers: {
                  "Content-Type": "application/json",
                  "x-goog-api-key": cleanApiKey,
                },
                body: jsonEncode(bodyMap),
              )
              .timeout(const Duration(seconds: 12));

          if (response.statusCode == 200) {
            final jsonBody = jsonDecode(response.body);
            final text = jsonBody["candidates"]?[0]?["content"]?["parts"]?[0]
                ?["text"];
            if (text != null) {
              lastAiError = null;
              if (cleanCand != requestedModel) {
                await updateSettings("geminiModel", cleanCand,
                    updateGlobalState: false);
              }
              return _parseJsonResponse(text,
                  rawMessage: rawMessage, provider: "Gemini ($cleanCand)");
            }
          } else {
            try {
              final errJson = jsonDecode(response.body);
              lastDetail = errJson["error"]?["message"] ?? response.body;
            } catch (_) {
              lastDetail = "HTTP ${response.statusCode}: ${response.body}";
            }
          }
        } catch (e) {
          debugPrint("Gemini attempt error for $cleanCand ($apiVersion): $e");
          lastDetail = e.toString();
        }
      }
    }

    // If all candidate attempts failed, query the user's available model list
    try {
      final available = await listGeminiModels(cleanApiKey);
      final isQuotaOrBilling = lastDetail.toLowerCase().contains("quota") ||
          lastDetail.toLowerCase().contains("exhausted") ||
          lastDetail.toLowerCase().contains("billing") ||
          lastDetail.toLowerCase().contains("limit");

      if (available.isNotEmpty) {
        final freeList = available
            .where((m) => m["isFree"] == true)
            .map((m) => m["model"] as String)
            .toList();
        final paidList = available
            .where((m) => m["isFree"] != true)
            .map((m) => m["model"] as String)
            .toList();

        if (isQuotaOrBilling) {
          lastAiError =
              "Google Quota / Billing limitation for '$requestedModel':\n$lastDetail\n\n"
              "💡 Explanation: Pro models require an active billing account in Google Cloud / AI Studio. "
              "For 100% free usage without billing, switch model to: "
              "${freeList.isNotEmpty ? freeList.join(', ') : 'gemini-flash-latest or gemini-2.5-flash'}.";
        } else {
          lastAiError =
              "Google API error for '$requestedModel':\n$lastDetail\n\n" +
              (freeList.isNotEmpty
                  ? "🟢 Free models available for your key: ${freeList.join(', ')}\n"
                  : "") +
              (paidList.isNotEmpty
                  ? "🟡 Paid / billing required: ${paidList.join(', ')}\n"
                  : "") +
              "Tip: Select 'gemini-flash-latest' or 'gemini-2.5-flash' in AI Settings.";
        }
      } else {
        lastAiError =
            "Gemini API key is invalid or Generative Language API is not enabled in your Google Cloud / AI Studio project.\nDetail: $lastDetail";
      }
    } catch (_) {
      lastAiError =
          "Gemini API error for '$requestedModel'. Detail: $lastDetail";
    }
    return null;
  }

  /// Groq (Ultra-Fast Cloud Llama 3.3 / Llama 3.1 with automatic candidate failover)
  static Future<LlmClassificationResult?> _classifyWithGroq(
      String rawMessage, String apiKey, {String? model}) async {
    final cleanApiKey = apiKey.trim();
    final requestedModel = (model != null && model.isNotEmpty)
        ? model.trim()
        : (appStateSettings["groqModel"]?.toString().trim().isNotEmpty == true
            ? appStateSettings["groqModel"]!.toString().trim()
            : "llama-3.3-70b-versatile");

    final candidates = [
      requestedModel,
      if (requestedModel != "llama-3.3-70b-versatile")
        "llama-3.3-70b-versatile",
      if (requestedModel != "llama-3.1-8b-instant") "llama-3.1-8b-instant",
      if (requestedModel != "gemma2-9b-it") "gemma2-9b-it",
    ];

    final url = Uri.parse("https://api.groq.com/openai/v1/chat/completions");

    for (final candidate in candidates) {
      try {
        final response = await http
            .post(
              url,
              headers: {
                "Content-Type": "application/json",
                "Authorization": "Bearer $cleanApiKey",
              },
              body: jsonEncode({
                "model": candidate,
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
            if (candidate != requestedModel) {
              await updateSettings("groqModel", candidate,
                  updateGlobalState: false);
            }
            return _parseJsonResponse(text,
                rawMessage: rawMessage, provider: "Groq ($candidate)");
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
          debugPrint("Groq candidate $candidate failed: $detail");
        }
      } catch (e) {
        lastAiError = e.toString();
        debugPrint("Groq attempt exception for $candidate: $e");
      }
    }
    return null;
  }

  /// OpenRouter (Any Cloud Model - Llama 3.3, Gemini 2.0 Flash, Mistral, Claude with automatic free failover)
  static Future<LlmClassificationResult?> _classifyWithOpenRouter(
      String rawMessage, String apiKey, {String? model}) async {
    final cleanApiKey = apiKey.trim();
    final requestedModel = (model != null && model.isNotEmpty)
        ? model.trim()
        : (appStateSettings["openRouterModel"]
                    ?.toString()
                    .trim()
                    .isNotEmpty ==
                true
            ? appStateSettings["openRouterModel"]!.toString().trim()
            : "meta-llama/llama-3.3-70b-instruct:free");

    final candidates = [
      requestedModel,
      if (requestedModel != "meta-llama/llama-3.3-70b-instruct:free")
        "meta-llama/llama-3.3-70b-instruct:free",
      if (requestedModel != "google/gemini-2.0-flash-exp:free")
        "google/gemini-2.0-flash-exp:free",
      if (requestedModel != "deepseek/deepseek-r1:free")
        "deepseek/deepseek-r1:free",
    ];

    final url = Uri.parse("https://openrouter.ai/api/v1/chat/completions");

    for (final candidate in candidates) {
      try {
        final response = await http
            .post(
              url,
              headers: {
                "Content-Type": "application/json",
                "Authorization": "Bearer $cleanApiKey",
                "HTTP-Referer": "https://cashewapp.web.app",
                "X-Title": "Cashew Budget Review",
              },
              body: jsonEncode({
                "model": candidate,
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
            if (candidate != requestedModel) {
              await updateSettings("openRouterModel", candidate,
                  updateGlobalState: false);
            }
            return _parseJsonResponse(text,
                rawMessage: rawMessage,
                provider: "OpenRouter ($candidate)");
          }
        } else {
          String detail = "OpenRouter HTTP ${response.statusCode}";
          try {
            final errJson = jsonDecode(response.body);
            final msg = errJson["error"]?["message"];
            if (msg != null) detail = "OpenRouter: $msg";
          } catch (_) {
            detail =
                "OpenRouter HTTP ${response.statusCode}: ${response.body}";
          }
          lastAiError = detail;
          debugPrint("OpenRouter candidate $candidate failed: $detail");
        }
      } catch (e) {
        lastAiError = e.toString();
        debugPrint("OpenRouter attempt exception for $candidate: $e");
      }
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
