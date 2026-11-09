import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsReview/reviewModels.dart';
import 'package:budget/struct/smsReview/smsParser.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
import 'package:budget/struct/backupShare/backupShareManager.dart';

const _uuid = Uuid();
const String _kReviewInboxStorageKey = "cached_review_transactions_v1";

class ReviewManager {
  static final ReviewManager instance = ReviewManager._internal();
  ReviewManager._internal();

  final List<ReviewTransaction> _items = [];
  final ValueNotifier<int> pendingCountNotifier = ValueNotifier<int>(0);
  bool _initialized = false;

  List<ReviewTransaction> get pendingTransactions =>
      List.unmodifiable(_items.where((i) => i.status == ReviewStatus.pending));

  List<ReviewTransaction> get allTransactions => List.unmodifiable(_items);

  /// Initialize and load saved unreviewed transactions from disk
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await loadFromStorage();
  }

  /// Load pending items from local settings/storage
  Future<void> loadFromStorage() async {
    try {
      final raw = appStateSettings[_kReviewInboxStorageKey];
      if (raw != null && raw is String && raw.isNotEmpty) {
        final List<dynamic> list = jsonDecode(raw);
        _items.clear();
        for (final item in list) {
          final tx = ReviewTransaction.fromJson(item as Map<String, dynamic>);
          // Self-heal amounts, currency, and account hints for pending items from original SMS
          if (tx.status == ReviewStatus.pending && tx.rawMessage.isNotEmpty) {
            final parsed = SmsParser.parse(tx.rawMessage);
            if (parsed.success && parsed.amount > 0) {
              if ((tx.amount - parsed.amount).abs() > 0.01) {
                tx.amount = parsed.amount;
              }
              tx.currency = parsed.currency;
              final clean = AiCategorizer.cleanMerchantName(parsed.rawMerchant);
              if (clean.isNotEmpty && clean != "Other") {
                tx.cleanMerchant = clean;
              }
            }
            if (parsed.accountHint != null && parsed.accountHint!.isNotEmpty) {
              tx.accountHint = canonicalizeAccountName(parsed.accountHint!);
            }
          }
          _items.add(tx);
        }
        await saveToStorage();
        _updateCount();
      }
    } catch (e) {
      debugPrint("Error loading review inbox items: $e");
    }
  }

  /// Persist items to local settings/storage
  Future<void> saveToStorage() async {
    try {
      final jsonList = _items.map((i) => i.toJson()).toList();
      await updateSettings(_kReviewInboxStorageKey, jsonEncode(jsonList),
          updateGlobalState: false);
      _updateCount();
    } catch (e) {
      debugPrint("Error saving review inbox items: $e");
    }
  }

  void _updateCount() {
    pendingCountNotifier.value =
        _items.where((i) => i.status == ReviewStatus.pending).length;
  }

  /// Process multiple SMS or notification messages at once
  Future<List<ReviewTransaction>> processBatchMessages(String multiTextMessage) async {
    final chunks = SmsParser.splitBatchMessages(multiTextMessage);
    final results = <ReviewTransaction>[];
    for (final chunk in chunks) {
      final item = await processRawMessage(chunk);
      if (item != null) {
        results.add(item);
      }
    }
    return results;
  }

  /// Process an incoming raw message string (SMS, WhatsApp, Push Notification)
  Future<ReviewTransaction?> processRawMessage(String rawMessage, {DateTime? overrideDate}) async {
    final provider = appStateSettings["aiProvider"]?.toString() ?? "none";
    ReviewTransaction? reviewItem;
    DateTime? effectiveDate = overrideDate;

    // 1. If Gemini or Ollama AI is enabled, query LLM classifier first
    if (provider == "gemini" || provider == "ollama") {
      final llmResult = await LlmClassifier.classify(rawMessage);
      if (llmResult != null) {
        if (!llmResult.isTransaction || llmResult.amount <= 0) {
          // AI correctly classified as advertisement, balance inquiry, or spam!
          return null;
        }

        effectiveDate = overrideDate ?? llmResult.date ?? SmsParser.extractDate(rawMessage);
        final cleanTitle = AiCategorizer.cleanMerchantName(llmResult.merchant);
        final aiSuggestion = await AiCategorizer.suggestCategory(cleanTitle, isIncome: llmResult.transactionType == "credit");

        reviewItem = ReviewTransaction(
          rawMessage: rawMessage,
          extractedTitle: llmResult.merchant,
          cleanMerchant: cleanTitle,
          amount: llmResult.amount,
          currency: llmResult.currency,
          date: effectiveDate,
          isIncome: llmResult.transactionType == "credit",
          suggestedCategoryName: llmResult.category != "Other" ? llmResult.category : aiSuggestion.categoryName,
          suggestedCategoryPk: aiSuggestion.categoryPk,
          confidence: llmResult.confidence,
          accountHint: llmResult.accountHint,
          isReminder: llmResult.isReminder,
        );
      }
    }

    // 2. Fallback to enhanced deterministic edge rule parser
    if (reviewItem == null) {
      final parsed = SmsParser.parse(rawMessage);
      if (!parsed.success) return null;
      effectiveDate = overrideDate ?? parsed.date;

      reviewItem = await SmsParser.createReviewTransaction(
        rawMessage,
        overrideDate: effectiveDate,
      );
    }

    // Check if duplicate message already pending
    final isDuplicate = _items.any((item) =>
        item.status == ReviewStatus.pending &&
        (item.rawMessage.trim() == rawMessage.trim() ||
            (item.amount == reviewItem!.amount &&
                item.cleanMerchant == reviewItem.cleanMerchant &&
                item.date.difference(effectiveDate!).inMinutes.abs() < 5)));

    if (isDuplicate) return null;

    // Normalize hint to canonical form and match existing wallet
    if (reviewItem.accountHint != null && reviewItem.accountHint!.isNotEmpty) {
      reviewItem.accountHint = canonicalizeAccountName(reviewItem.accountHint!);
      final wallets = await database.getAllWallets();
      final matchingWallet =
          findMatchingWallet(wallets, reviewItem.accountHint!);
      if (matchingWallet != null) {
        reviewItem.suggestedWalletPk = matchingWallet.walletPk;
      }
    }

    _items.insert(0, reviewItem);
    await saveToStorage();
    return reviewItem;
  }

  /// Approve a single transaction and commit to Cashew DB
  Future<bool> approve(ReviewTransaction item,
      {String? customWalletPk, String? customCategoryPk}) async {
    try {
      // Determine wallet: ensure dedicated account for Bank, Card, or Cash without dumping into default!
      String walletPk = customWalletPk ?? item.suggestedWalletPk ?? "";
      final wallets = await database.getAllWallets();

      if (walletPk.isEmpty) {
        final hint = item.accountHint?.trim();
        if (hint != null && hint.isNotEmpty) {
          final canonicalName = canonicalizeAccountName(hint);
          final existingWallet = findMatchingWallet(wallets, hint);

          if (existingWallet != null) {
            walletPk = existingWallet.walletPk;
          } else {
            // Open account once with clean canonical name!
            walletPk = _uuid.v4();
            await database.createOrUpdateWallet(
              TransactionWallet(
                walletPk: walletPk,
                name: canonicalName,
                currency: (item.currency == "INR" || item.currency == "₹")
                    ? "inr"
                    : item.currency.toLowerCase(),
                dateCreated: DateTime.now(),
                order: wallets.length,
                decimals: 2,
                homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
              ),
            );
          }
        } else {
          // No hint available, pick selected wallet or first
          walletPk = appStateSettings["selectedWalletPk"] ??
              (wallets.isNotEmpty ? wallets.first.walletPk : "0");
        }
      }

      // Determine category
      String categoryPk = customCategoryPk ?? item.suggestedCategoryPk ?? "";
      if (categoryPk.isEmpty) {
        final categories = await database.getAllCategories();
        if (categories.isNotEmpty) {
          categoryPk = categories.first.categoryPk;
        }
      }

      // Amount: negative for expense, positive for income
      double finalAmount =
          item.isIncome ? item.amount.abs() : -item.amount.abs();

      final newTransaction = Transaction(
        transactionPk: _uuid.v4(),
        name: item.cleanMerchant,
        amount: finalAmount,
        note: "Auto-logged from SMS/Notification:\n${item.rawMessage}",
        categoryFk: categoryPk,
        walletFk: walletPk,
        dateCreated: item.date,
        income: item.isIncome,
        paid: true,
        skipPaid: false,
        transactionOwnerEmail: getCurrentUserIdentifier(),
      );

      await database.createOrUpdateTransaction(newTransaction, insert: true);

      // Learn association for future AI classification
      if (categoryPk.isNotEmpty && item.cleanMerchant.isNotEmpty) {
        try {
          await database.createOrUpdateAssociatedTitle(
            TransactionAssociatedTitle(
              associatedTitlePk: _uuid.v4(),
              title: item.cleanMerchant,
              categoryFk: categoryPk,
              dateCreated: DateTime.now(),
              order: 0,
              isExactMatch: false,
            ),
            insert: true,
          );
        } catch (_) {}
      }

      // Update status and remove from active list or mark approved
      _items.removeWhere((i) => i.id == item.id);
      await saveToStorage();
      return true;
    } catch (e) {
      debugPrint("Error approving transaction: $e");
      return false;
    }
  }

  /// Update category for a merchant across all pending items and persist to database AssociatedTitle
  Future<void> updateCategoryForMerchant({
    required String merchant,
    required String categoryName,
    required String? categoryPk,
    bool applyEverywhere = true,
  }) async {
    for (final item in _items) {
      if (item.status == ReviewStatus.pending &&
          (item.cleanMerchant.toLowerCase() == merchant.toLowerCase() ||
              item.extractedTitle.toLowerCase() == merchant.toLowerCase())) {
        item.suggestedCategoryName = categoryName;
        item.suggestedCategoryPk = categoryPk;
        item.confidence = 1.0;
      }
    }
    await saveToStorage();

    if (applyEverywhere && categoryPk != null && categoryPk.isNotEmpty) {
      try {
        await database.createOrUpdateAssociatedTitle(
          TransactionAssociatedTitle(
            associatedTitlePk: _uuid.v4(),
            title: merchant,
            categoryFk: categoryPk,
            dateCreated: DateTime.now(),
            order: 0,
            isExactMatch: false,
          ),
          insert: true,
        );
      } catch (e) {
        debugPrint("Error creating associated title: $e");
      }
    }
  }

  /// Dismiss/Ignore a transaction
  Future<void> dismiss(ReviewTransaction item) async {
    _items.removeWhere((i) => i.id == item.id);
    await saveToStorage();
  }

  /// Approve all pending transactions in one tap
  Future<int> approveAll() async {
    int count = 0;
    final toApprove = List<ReviewTransaction>.from(pendingTransactions);
    for (final item in toApprove) {
      final success = await approve(item);
      if (success) count++;
    }
    return count;
  }

  /// Clear the inbox
  Future<void> clearAll() async {
    _items.clear();
    await saveToStorage();
  }

  /// Normalizes any account variation (e.g. "HDFC 4340", "HDFC A/C 4340", "HDFC Bank A/C *4340", "HDFC *4340")
  /// into a single canonical format (e.g. "HDFC A/C *4340").
  static String canonicalizeAccountName(String hint) {
    final trimmed = hint.trim();
    if (trimmed.isEmpty) return "";
    final lower = trimmed.toLowerCase();

    // Cash / ATM
    if (lower == "cash" ||
        lower.contains("atm") ||
        lower.contains("cash withdrawal")) {
      return "Cash";
    }

    // Extract digits (e.g. "4340")
    final digitsMatch = RegExp(r'(\d{3,6})').firstMatch(trimmed);
    final digits = digitsMatch?.group(1);

    // Detect Bank
    String? bank;
    final bankRegex = RegExp(
      r'\b(HDFC|SBI|State\s+Bank\s+of\s+India|ICICI|Axis|Kotak|PNB|Punjab\s+National\s+Bank|Canara|Bank\s+of\s+Baroda|BOB|IDFC|IndusInd|Yes\s+Bank|YES|Federal\s+Bank|Standard\s+Chartered|Citi(?:bank)?|HSBC|RBL|Union\s+Bank|Indian\s+Bank|BOI|Bank\s+of\s+India|Central\s+Bank|IOB|Indian\s+Overseas\s+Bank|UCO|South\s+Indian\s+Bank|Karur\s+Vysya|KVB|DBS|AU|Bandhan|Paytm|Airtel)\b',
      caseSensitive: false,
    );
    final bankMatch = bankRegex.firstMatch(trimmed);
    if (bankMatch != null) {
      final b = bankMatch.group(0)?.trim() ?? "";
      final bLower = b.toLowerCase();
      if (bLower.contains("hdfc")) {
        bank = "HDFC";
      } else if (bLower.contains("sbi") || bLower.contains("state bank")) {
        bank = "SBI";
      } else if (bLower.contains("icici")) {
        bank = "ICICI";
      } else if (bLower.contains("axis")) {
        bank = "Axis";
      } else if (bLower.contains("kotak")) {
        bank = "Kotak";
      } else if (bLower.contains("rbl")) {
        bank = "RBL";
      } else if (bLower.contains("pnb") || bLower.contains("punjab")) {
        bank = "PNB";
      } else if (bLower.contains("idfc")) {
        bank = "IDFC";
      } else if (bLower.contains("bob") || bLower.contains("baroda")) {
        bank = "Bank of Baroda";
      } else if (bLower.contains("canara")) {
        bank = "Canara";
      } else if (bLower.contains("indusind")) {
        bank = "IndusInd";
      } else if (bLower.contains("yes")) {
        bank = "Yes Bank";
      } else {
        bank = b;
      }
    }

    // Detect Card vs Account
    final isCreditCard = lower.contains("credit") ||
        (lower.contains("card") && !lower.contains("debit")) ||
        RegExp(r'\bcc\b').hasMatch(lower);
    final isDebitCard = lower.contains("debit");

    final maskStr = digits != null ? "*$digits" : null;

    if (bank != null && isCreditCard) {
      return "$bank Credit Card${maskStr != null ? ' $maskStr' : ''}";
    } else if (bank != null && isDebitCard) {
      return "$bank Debit Card${maskStr != null ? ' $maskStr' : ''}";
    } else if (bank != null && maskStr != null) {
      return "$bank A/C $maskStr";
    } else if (bank != null) {
      return "$bank Bank";
    } else if (isCreditCard && maskStr != null) {
      return "Credit Card $maskStr";
    } else if (isCreditCard) {
      return "Credit Card";
    } else if (maskStr != null) {
      return "A/C $maskStr";
    }

    return trimmed;
  }

  /// Finds an existing wallet that matches the given account hint, even across variations
  /// like "HDFC A/C *4340", "HDFC A/C 4340", "HDFC 4340", etc.
  static TransactionWallet? findMatchingWallet(
      List<TransactionWallet> wallets, String hint) {
    final trimmed = hint.trim();
    if (trimmed.isEmpty) return null;

    final canonical = canonicalizeAccountName(trimmed);

    // 1. Check exact match on name or canonical name
    for (final w in wallets) {
      if (w.name.trim().toLowerCase() == trimmed.toLowerCase() ||
          w.name.trim().toLowerCase() == canonical.toLowerCase()) {
        return w;
      }
    }

    // 2. Check canonical equivalence (e.g. existing wallet is "HDFC 4340" and hint is "HDFC A/C *4340")
    for (final w in wallets) {
      if (canonicalizeAccountName(w.name).toLowerCase() ==
          canonical.toLowerCase()) {
        return w;
      }
    }

    // 3. Bank + Account Number digits matching
    // E.g. both have "HDFC" and digits "4340", and neither conflicts on Card vs Account
    final hintDigits = trimmed.replaceAll(RegExp(r'\D'), '');
    final hintLower = trimmed.toLowerCase();
    final isHintCreditCard = hintLower.contains("credit") ||
        (hintLower.contains("card") && !hintLower.contains("debit")) ||
        RegExp(r'\bcc\b').hasMatch(hintLower);
    final isHintExplicitAccount = hintLower.contains("a/c") ||
        hintLower.contains("acct") ||
        hintLower.contains("account");

    if (hintDigits.length >= 3) {
      for (final w in wallets) {
        final wDigits = w.name.replaceAll(RegExp(r'\D'), '');
        final wLower = w.name.toLowerCase();
        final isWCreditCard = wLower.contains("credit") ||
            (wLower.contains("card") && !wLower.contains("debit")) ||
            RegExp(r'\bcc\b').hasMatch(wLower);

        // Don't mix Credit Cards with Checking/Savings A/Cs if explicitly indicated
        if (isHintExplicitAccount && isWCreditCard) continue;
        if (isHintCreditCard && !isWCreditCard) continue;

        if (wDigits.contains(hintDigits) || hintDigits.contains(wDigits)) {
          // Check bank brand compatibility if present in both
          final bankInW = _extractBankBrand(w.name);
          final bankInHint = _extractBankBrand(trimmed);
          if (bankInW != null && bankInHint != null && bankInW != bankInHint) {
            continue; // Different banks (e.g. SBI vs HDFC), do not match
          }
          return w;
        }
      }
    }

    // 4. Substring / contains match
    for (final w in wallets) {
      final wLower = w.name.toLowerCase();
      final isWCreditCard = wLower.contains("credit") ||
          (wLower.contains("card") && !wLower.contains("debit")) ||
          RegExp(r'\bcc\b').hasMatch(wLower);
      if (isHintCreditCard != isWCreditCard) continue;

      if (w.name.toLowerCase().contains(trimmed.toLowerCase()) ||
          trimmed.toLowerCase().contains(w.name.toLowerCase())) {
        return w;
      }
    }

    return null;
  }

  static String? _extractBankBrand(String str) {
    final lower = str.toLowerCase();
    if (lower.contains("hdfc")) return "hdfc";
    if (lower.contains("sbi") || lower.contains("state bank")) return "sbi";
    if (lower.contains("icici")) return "icici";
    if (lower.contains("axis")) return "axis";
    if (lower.contains("kotak")) return "kotak";
    if (lower.contains("rbl")) return "rbl";
    if (lower.contains("pnb") || lower.contains("punjab")) return "pnb";
    if (lower.contains("canara")) return "canara";
    if (lower.contains("idfc")) return "idfc";
    if (lower.contains("bob") || lower.contains("baroda")) return "bob";
    if (lower.contains("indusind")) return "indusind";
    if (lower.contains("yes")) return "yes";
    if (lower.contains("federal")) return "federal";
    return null;
  }
}
