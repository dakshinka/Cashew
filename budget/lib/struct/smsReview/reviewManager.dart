import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsReview/reviewModels.dart';
import 'package:budget/struct/smsReview/smsParser.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
import 'package:budget/struct/smsReview/smsDiagnosticTracker.dart';
import 'package:budget/struct/backupShare/backupShareManager.dart';
import 'package:budget/struct/statementImporter/statementParser.dart';
import 'package:budget/struct/categoryManagerHelper.dart';
import 'package:budget/widgets/navigationFramework.dart';

const _uuid = Uuid();
const String _kReviewInboxStorageKey = "cached_review_transactions_v1";

class ReviewManager {
  static final ReviewManager instance = ReviewManager._internal();
  ReviewManager._internal();

  final List<ReviewTransaction> _items = [];
  final ValueNotifier<int> pendingCountNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> ignoredCountNotifier = ValueNotifier<int>(0);
  bool _initialized = false;

  List<ReviewTransaction> get pendingTransactions =>
      List.unmodifiable(_items.where((i) => i.status == ReviewStatus.pending));

  List<ReviewTransaction> get ignoredMessages =>
      List.unmodifiable(_items.where((i) => i.status == ReviewStatus.ignored));

  List<ReviewTransaction> get allTransactions => List.unmodifiable(_items);

  static const String _kAccountBindingsKey = "smsAccountWalletBindings";

  /// Gets the map of raw account hints/digits -> bound walletPk
  Map<String, String> getAccountBindings() {
    final raw = appStateSettings[_kAccountBindingsKey]?.toString();
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, String>.from(decoded);
      }
    } catch (_) {}
    return {};
  }

  /// Saves account binding mapping
  Future<void> saveAccountBinding(String accountPattern, String walletPk) async {
    final bindings = getAccountBindings();
    bindings[accountPattern.toLowerCase().trim()] = walletPk;
    final digits = accountPattern.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 3) {
      bindings[digits] = walletPk;
    }
    await updateSettings(_kAccountBindingsKey, jsonEncode(bindings),
        updateGlobalState: false);
  }

  /// Bind wallet for account across past, present, and future transactions
  Future<void> updateWalletForAccount({
    required String accountHint,
    String? walletPk,
    String? walletName,
    bool applyEverywhere = true,
  }) async {
    final normalized = canonicalizeAccountName(accountHint);
    final digits = accountHint.replaceAll(RegExp(r'\D'), '');

    if (applyEverywhere && walletPk != null && walletPk.isNotEmpty) {
      await saveAccountBinding(accountHint, walletPk);
      if (digits.length >= 3) {
        await saveAccountBinding(digits, walletPk);
      }
    }

    // 1. Update all matching pending review transactions
    for (final item in _items) {
      if (item.status == ReviewStatus.pending) {
        final itemHint = item.accountHint ?? "";
        final itemDigits = itemHint.replaceAll(RegExp(r'\D'), '');
        if (itemHint.toLowerCase() == accountHint.toLowerCase() ||
            canonicalizeAccountName(itemHint).toLowerCase() ==
                normalized.toLowerCase() ||
            (digits.isNotEmpty && itemDigits == digits)) {
          item.suggestedWalletPk = walletPk;
          if (walletName != null && walletName.isNotEmpty) {
            item.accountHint = walletName;
          }
        }
      }
    }
    await saveToStorage();

    // 2. If applyEverywhere, update matching past transactions in the database!
    if (applyEverywhere && walletPk != null && walletPk.isNotEmpty) {
      try {
        final allTxns = await database.allTransactions;
        for (final t in allTxns) {
          final note = t.note;
          if (note.toLowerCase().contains(accountHint.toLowerCase()) ||
              (digits.isNotEmpty &&
                  digits.length >= 3 &&
                  note.contains(digits))) {
            if (t.walletFk != walletPk) {
              await database.createOrUpdateTransaction(
                t.copyWith(walletFk: walletPk),
              );
            }
          }
        }
      } catch (e) {
        debugPrint("Error updating past transactions for account: $e");
      }
    }
  }

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
          // Self-heal items: re-extract correct account hints, convert future notices/e-mandates to ignored tab
          if (tx.rawMessage.isNotEmpty) {
            if (SmsParser.isInformationalOrFutureNotice(tx.rawMessage)) {
              if (tx.status == ReviewStatus.pending) {
                // Move future e-mandates and scheduled notices to ignored tab
                tx.status = ReviewStatus.ignored;
              }
            } else if (tx.status == ReviewStatus.pending) {
              final fixedHint =
                  SmsParser.extractAccountHint(tx.rawMessage, amount: tx.amount);
              if (fixedHint != null && fixedHint.isNotEmpty) {
                tx.accountHint = canonicalizeAccountName(fixedHint);
              }
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
    ignoredCountNotifier.value =
        _items.where((i) => i.status == ReviewStatus.ignored).length;
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

  void _recordIgnoredMessage(String rawMessage,
      {String? reason, DateTime? overrideDate}) {
    if (_items.any((i) => i.rawMessage.trim() == rawMessage.trim())) return;
    final extractedAmount =
        SmsParser.extractAmountFromText(rawMessage) ?? 0.0;
    final ignoredItem = ReviewTransaction(
      rawMessage: rawMessage,
      extractedTitle: "Ignored SMS",
      cleanMerchant: "Non-Transaction",
      amount: extractedAmount,
      date: overrideDate ?? SmsParser.extractDate(rawMessage),
      isIncome: false,
      suggestedCategoryName: "Other",
      status: ReviewStatus.ignored,
      ignoredReason: reason ?? "Filtered non-transaction",
    );
    _items.insert(0, ignoredItem);
    saveToStorage();
    _updateCount();
  }

  /// Converts an ignored / non-transaction SMS into an active pending review transaction,
  /// and asks the AI to learn why this message was previously missed.
  Future<ReviewTransaction?> convertIgnoredToTransaction(
      ReviewTransaction item) async {
    final parsed = SmsParser.parse(item.rawMessage);
    double amt = item.amount > 0
        ? item.amount
        : (parsed.amount > 0
            ? parsed.amount
            : (SmsParser.extractAmountFromText(item.rawMessage) ?? 0.0));
    final lower = item.rawMessage.toLowerCase();
    bool isIncome = parsed.isIncome ||
        lower.contains("deposited") ||
        lower.contains("depoisited") ||
        lower.contains("credited") ||
        lower.contains("salary");
    String merchant = parsed.rawMerchant.isNotEmpty &&
            parsed.rawMerchant != "Bank Transfer"
        ? parsed.rawMerchant
        : SmsParser.extractMerchant(item.rawMessage, isCredit: isIncome);
    String cleanMerchant = AiCategorizer.cleanMerchantName(merchant);
    String? accountHint = parsed.accountHint ??
        SmsParser.extractAccountHint(item.rawMessage, amount: amt);

    item.amount = amt;
    item.isIncome = isIncome;
    item.cleanMerchant = cleanMerchant.isNotEmpty
        ? cleanMerchant
        : (isIncome ? "Salary / Credit" : "Expense");
    if (accountHint != null && accountHint.isNotEmpty) {
      item.accountHint = canonicalizeAccountName(accountHint);
    }
    item.date = parsed.date;
    item.status = ReviewStatus.pending;
    item.confidence = 1.0;

    // Call LLM to learn why this transaction was missed and generate permanent rule
    try {
      await LlmClassifier.teachMissedTransaction(item.rawMessage);
    } catch (_) {}

    await saveToStorage();
    _updateCount();
    return item;
  }

  Future<void> deleteIgnored(ReviewTransaction item) async {
    _items.removeWhere((i) => i.id == item.id);
    await saveToStorage();
    _updateCount();
  }

  Future<void> clearAllIgnored() async {
    _items.removeWhere((i) => i.status == ReviewStatus.ignored);
    await saveToStorage();
    _updateCount();
  }

  /// Process an incoming raw message string (SMS, WhatsApp, Push Notification)
  Future<ReviewTransaction?> processRawMessage(String rawMessage,
      {DateTime? overrideDate, String sender = "SMS"}) async {
    final provider = appStateSettings["aiProvider"]?.toString() ?? "none";
    final hasNumbers = RegExp(r'\d{2,}').hasMatch(rawMessage);

    if (SmsParser.isInformationalOrFutureNotice(rawMessage)) {
      if (hasNumbers) {
        _recordIgnoredMessage(rawMessage,
            reason: "Informational notice or future reminder",
            overrideDate: overrideDate);
        SmsDiagnosticTracker.instance.log(
          sender: sender,
          rawMessage: rawMessage,
          timestamp: overrideDate ?? DateTime.now(),
          status: "other_sms",
          reason: "Moved to Other SMS (Informational alert / future reminder)",
        );
      } else {
        SmsDiagnosticTracker.instance.log(
          sender: sender,
          rawMessage: rawMessage,
          timestamp: overrideDate ?? DateTime.now(),
          status: "skipped",
          reason: "Skipped: Informational alert without transacted amount",
        );
      }
      return null;
    }

    ReviewTransaction? reviewItem;
    DateTime? effectiveDate = overrideDate;

    // 1. FIRST: Run 100% offline edge rules & persistent learned regex patterns (Zero latency, Zero AI calls)
    final localParsed = SmsParser.parse(rawMessage);
    if (localParsed.success && localParsed.amount > 0) {
      effectiveDate = overrideDate ?? localParsed.date;
      reviewItem = await SmsParser.createReviewTransaction(
        rawMessage,
        overrideDate: effectiveDate,
      );
    } else if ((provider == "gemini" ||
            provider == "groq" ||
            provider == "openrouter" ||
            provider == "ollama") &&
        hasNumbers &&
        !SmsParser.isInformationalOrFutureNotice(rawMessage)) {
      // 2. Only if local parsing FAILED and message contains numbers, invoke AI as fallback pattern builder
      final llmResult = await LlmClassifier.classify(rawMessage);
      if (llmResult != null) {
        if (!llmResult.isTransaction || llmResult.amount <= 0) {
          if (hasNumbers) {
            _recordIgnoredMessage(rawMessage,
                reason: llmResult.reasoning ??
                    "Classified by AI as non-transaction",
                overrideDate: overrideDate);
            SmsDiagnosticTracker.instance.log(
              sender: sender,
              rawMessage: rawMessage,
              timestamp: overrideDate ?? DateTime.now(),
              status: "other_sms",
              reason: llmResult.reasoning ??
                  "Moved to Other SMS (Classified by AI as non-transaction)",
            );
          } else {
            SmsDiagnosticTracker.instance.log(
              sender: sender,
              rawMessage: rawMessage,
              timestamp: overrideDate ?? DateTime.now(),
              status: "skipped",
              reason: llmResult.reasoning ?? "Skipped by AI (No transaction)",
            );
          }
          return null;
        } else {
          // Reject future notices / mandates hallucinated by LLM as transactions
          if (SmsParser.isInformationalOrFutureNotice(rawMessage)) {
            if (hasNumbers) {
              _recordIgnoredMessage(rawMessage,
                  reason: "E-Mandate / Future scheduled notice",
                  overrideDate: overrideDate);
              SmsDiagnosticTracker.instance.log(
                sender: sender,
                rawMessage: rawMessage,
                timestamp: overrideDate ?? DateTime.now(),
                status: "other_sms",
                reason: "Moved to Other SMS (E-Mandate / Future scheduled notice)",
              );
            }
            return null;
          }

          effectiveDate = overrideDate ??
              llmResult.date ??
              SmsParser.extractDate(rawMessage);
          final cleanTitle =
              AiCategorizer.cleanMerchantName(llmResult.merchant);
          final aiSuggestion = await AiCategorizer.suggestCategory(cleanTitle,
              isIncome: llmResult.transactionType == "credit");

          // Ground accountHint with regex on the actual message text to prevent hallucinations
          final regexHint = SmsParser.extractAccountHint(rawMessage,
              amount: llmResult.amount);
          String? resolvedHint;
          if (regexHint != null && regexHint.isNotEmpty) {
            resolvedHint = canonicalizeAccountName(regexHint);
          } else if (llmResult.accountHint != null &&
              llmResult.accountHint!.isNotEmpty) {
            final cand = llmResult.accountHint!;
            final amtStr = llmResult.amount.toInt().toString();
            final candDigits = cand.replaceAll(RegExp(r'\D'), '');
            final isAmountInHint = amtStr.length >= 3 && candDigits == amtStr;
            final isMerchantInHint = cleanTitle.length >= 4 &&
                cand.toLowerCase().contains(cleanTitle.toLowerCase());
            if (!isAmountInHint && !isMerchantInHint) {
              resolvedHint = canonicalizeAccountName(cand);
            }
          }

          reviewItem = ReviewTransaction(
            rawMessage: rawMessage,
            extractedTitle: llmResult.merchant,
            cleanMerchant: cleanTitle,
            amount: llmResult.amount,
            currency: llmResult.currency,
            date: effectiveDate,
            isIncome: llmResult.transactionType == "credit",
            suggestedCategoryName: llmResult.category != "Other"
                ? llmResult.category
                : aiSuggestion.categoryName,
            suggestedCategoryPk: aiSuggestion.categoryPk,
            confidence: llmResult.confidence,
            accountHint: resolvedHint,
            isReminder: llmResult.isReminder,
          );

          // Asynchronously synthesize & persist an offline regex pattern so future SMS of this format require NO AI!
          LlmClassifier.synthesizeAndStoreRegexPattern(rawMessage, llmResult);
        }
      }
    }

    if (reviewItem == null) {
      if (hasNumbers) {
        _recordIgnoredMessage(rawMessage,
            reason: "No transaction keyword recognized",
            overrideDate: overrideDate);
        SmsDiagnosticTracker.instance.log(
          sender: sender,
          rawMessage: rawMessage,
          timestamp: overrideDate ?? DateTime.now(),
          status: "other_sms",
          reason:
              "Moved to Other SMS (Amount present but no debit/credit action keyword recognized)",
        );
      } else {
        SmsDiagnosticTracker.instance.log(
          sender: sender,
          rawMessage: rawMessage,
          timestamp: overrideDate ?? DateTime.now(),
          status: "skipped",
          reason: "Skipped: No financial numbers or keywords found",
        );
      }
      return null;
    }

    // Check if duplicate message already pending
    final isDuplicate = _items.any((item) =>
        item.status == ReviewStatus.pending &&
        (item.rawMessage.trim() == rawMessage.trim() ||
            (item.amount == reviewItem!.amount &&
                item.cleanMerchant == reviewItem.cleanMerchant &&
                item.date.difference(effectiveDate!).inMinutes.abs() < 5)));

    if (isDuplicate) {
      SmsDiagnosticTracker.instance.log(
        sender: sender,
        rawMessage: rawMessage,
        timestamp: effectiveDate ?? DateTime.now(),
        status: "duplicate",
        reason: "Skipped: Already pending in Review Inbox",
        detectedAmount: reviewItem.amount,
        detectedMerchant: reviewItem.cleanMerchant,
      );
      return null;
    }

    // Check against existing database transactions
    try {
      final allTxns = await database.allTransactions;
      final smsDateOnly =
          DateTime(effectiveDate!.year, effectiveDate.month, effectiveDate.day);
      final alreadyInDb = allTxns.any((t) {
        final txDateOnly = DateTime(
            t.dateCreated.year, t.dateCreated.month, t.dateCreated.day);
        final diffDays = txDateOnly.difference(smsDateOnly).inDays.abs();
        if (diffDays > 2) return false;

        final amountMatches =
            (t.amount.abs() - reviewItem!.amount.abs()).abs() < 0.01;
        if (!amountMatches) return false;

        final typeMatches = (t.income == reviewItem.isIncome);
        if (!typeMatches) return false;

        final dbRef = StatementParser.extractReferenceId(t.note);
        final smsRef = StatementParser.extractReferenceId(rawMessage);
        final refsMatch = StatementParser.areReferenceIdsMatching(dbRef, smsRef) ||
            StatementParser.notesShareReferenceId(t.note, rawMessage);

        if (dbRef != null && smsRef != null && dbRef.isNotEmpty && smsRef.isNotEmpty) {
          if (!refsMatch) return false;
        }

        // If reference IDs match, it is definitively the same transaction (allow up to 4 days for value date lag)
        if (refsMatch && diffDays <= 4) return true;

        if (diffDays > 2) return false;

        final tName = t.name.toLowerCase();
        final rName = reviewItem.cleanMerchant.toLowerCase();
        final nameMatches = tName == rName ||
            tName.contains(rName) ||
            rName.contains(tName) ||
            AiCategorizer.cleanMerchantName(t.name).toLowerCase() == rName;

        final noteMatches = t.note.contains(rawMessage.trim());

        return nameMatches || noteMatches || (diffDays <= 1);
      });
      if (alreadyInDb) {
        SmsDiagnosticTracker.instance.log(
          sender: sender,
          rawMessage: rawMessage,
          timestamp: effectiveDate,
          status: "duplicate",
          reason: "Skipped: Already recorded in Cashew database accounts",
          detectedAmount: reviewItem.amount,
          detectedMerchant: reviewItem.cleanMerchant,
        );
        return null;
      }
    } catch (_) {}

    // Normalize hint to canonical form and match existing wallet
    if (reviewItem.accountHint != null && reviewItem.accountHint!.isNotEmpty) {
      reviewItem.accountHint = canonicalizeAccountName(reviewItem.accountHint!);
      final wallets = await database.getAllWallets();
      final matchingWallet =
          findMatchingWallet(wallets, reviewItem.accountHint!);
      if (matchingWallet != null) {
        reviewItem.suggestedWalletPk = matchingWallet.walletPk;
      }

      // Check persistent account bindings (binded accounts)
      final bindings = getAccountBindings();
      final hintLower = reviewItem.accountHint!.toLowerCase().trim();
      final digits = hintLower.replaceAll(RegExp(r'\D'), '');
      if (bindings.containsKey(hintLower)) {
        reviewItem.suggestedWalletPk = bindings[hintLower];
      } else if (digits.isNotEmpty && bindings.containsKey(digits)) {
        reviewItem.suggestedWalletPk = bindings[digits];
      }
    }

    _items.insert(0, reviewItem);
    await saveToStorage();

    SmsDiagnosticTracker.instance.log(
      sender: sender,
      rawMessage: rawMessage,
      timestamp: effectiveDate ?? DateTime.now(),
      status: "captured",
      reason:
          "Captured: ${reviewItem.cleanMerchant} (${reviewItem.displayCurrency}${reviewItem.amount.toStringAsFixed(2)}) -> ${reviewItem.accountHint ?? 'Default Wallet'}",
      detectedAmount: reviewItem.amount,
      detectedMerchant: reviewItem.cleanMerchant,
      detectedAccount: reviewItem.accountHint,
      isIncome: reviewItem.isIncome,
    );

    return reviewItem;
  }

  /// Approve a single transaction and commit to Cashew DB
  Future<bool> approve(ReviewTransaction item,
      {String? customWalletPk,
      String? customCategoryPk,
      String? customSubCategoryPk}) async {
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

      // Determine category and subcategory
      String categoryPk = customCategoryPk ?? item.suggestedCategoryPk ?? "";
      String? subCategoryPk = customSubCategoryPk ?? item.suggestedSubCategoryPk;

      if (categoryPk.isEmpty) {
        final categories = await database.getAllCategories();
        if (CategoryManagerHelper.isFinancialOrCardCharge(item.rawMessage) ||
            CategoryManagerHelper.isFinancialOrCardCharge(item.cleanMerchant)) {
          final context = navigatorKey.currentContext;
          if (context != null) {
            final ensured = await CategoryManagerHelper.ensureFinancialCategoriesExist(
              context,
              askConfirmation: false,
            );
            if (ensured != null) {
              categoryPk = ensured['main']!.categoryPk;
              final subName = CategoryManagerHelper.getRecommendedSubCategoryName(
                  item.rawMessage.isNotEmpty ? item.rawMessage : item.cleanMerchant);
              if (subName == CategoryManagerHelper.subCatInterest) {
                subCategoryPk = ensured['interest']?.categoryPk;
              } else if (subName == CategoryManagerHelper.subCatEmi) {
                subCategoryPk = ensured['emi']?.categoryPk;
              } else if (subName == CategoryManagerHelper.subCatTaxes) {
                subCategoryPk = ensured['taxes']?.categoryPk;
              } else {
                subCategoryPk = ensured['charges']?.categoryPk;
              }
            }
          }
        }
        if (categoryPk.isEmpty && categories.isNotEmpty) {
          final found = categories.firstWhereOrNull((c) =>
              c.name.toLowerCase() == item.suggestedCategoryName.toLowerCase());
          categoryPk = found?.categoryPk ?? categories.first.categoryPk;
        }
      }

      // Amount: negative for expense, positive for income
      double finalAmount =
          item.isIncome ? item.amount.abs() : -item.amount.abs();

      // Prevent duplicate insertion if transaction is already in database
      try {
        final allTxns = await database.allTransactions;
        final itemDateOnly =
            DateTime(item.date.year, item.date.month, item.date.day);
        final alreadyLogged = allTxns.any((t) {
          final txDateOnly = DateTime(
              t.dateCreated.year, t.dateCreated.month, t.dateCreated.day);
          final diffDays = txDateOnly.difference(itemDateOnly).inDays.abs();
          final amountMatches =
              (t.amount.abs() - item.amount.abs()).abs() < 0.01;
          if (!amountMatches) return false;

          final typeMatches = (t.income == item.isIncome);
          if (!typeMatches) return false;

          final dbRef = StatementParser.extractReferenceId(t.note);
          final smsRef = StatementParser.extractReferenceId(item.rawMessage);
          final refsMatch = StatementParser.areReferenceIdsMatching(dbRef, smsRef) ||
              StatementParser.notesShareReferenceId(t.note, item.rawMessage);

          if (dbRef != null && smsRef != null && dbRef.isNotEmpty && smsRef.isNotEmpty) {
            if (!refsMatch) return false;
          }

          if (refsMatch && diffDays <= 4) return true;

          if (diffDays > 2) return false;

          final tName = t.name.toLowerCase();
          final rName = item.cleanMerchant.toLowerCase();
          final nameMatches = tName == rName ||
              tName.contains(rName) ||
              rName.contains(tName) ||
              AiCategorizer.cleanMerchantName(t.name).toLowerCase() == rName;

          final noteMatches = t.note.contains(item.rawMessage.trim());

          return nameMatches || noteMatches || (diffDays <= 1);
        });
        if (alreadyLogged) {
          item.status = ReviewStatus.approved;
          await saveToStorage();
          return true;
        }
      } catch (_) {}

      final refId = StatementParser.extractReferenceId(item.rawMessage);
      final method = StatementParser.extractPaymentMethod(item.rawMessage);
      final note = "[Source: SMS Notification]\n" +
          (refId != null ? "Ref ID: $refId\n" : "") +
          "Method: $method\n" +
          "Narration: ${item.rawMessage}";

      final newTransaction = Transaction(
        transactionPk: _uuid.v4(),
        name: item.cleanMerchant,
        amount: finalAmount,
        note: note,
        categoryFk: categoryPk,
        subCategoryFk: subCategoryPk,
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
    String? subCategoryName,
    String? subCategoryPk,
    bool applyEverywhere = true,
  }) async {
    for (final item in _items) {
      if (item.status == ReviewStatus.pending &&
          (item.cleanMerchant.toLowerCase() == merchant.toLowerCase() ||
              item.extractedTitle.toLowerCase() == merchant.toLowerCase())) {
        item.suggestedCategoryName = categoryName;
        item.suggestedCategoryPk = categoryPk;
        item.suggestedSubCategoryName = subCategoryName;
        item.suggestedSubCategoryPk = subCategoryPk;
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
      r'\b(HDFC|SBI|State\s+Bank\s+of\s+India|ICICI|Axis|Kotak|PNB|Punjab\s+National\s+Bank|Canara|Bank\s+of\s+Baroda|BOB|IDFC|IndusInd|Yes\s+Bank|YES|Federal\s+Bank|Standard\s+Chartered|Citi(?:bank)?|HSBC|RBL|Union\s+Bank|Indian\s+Bank|BOI|Bank\s+of\s+India|Central\s+Bank|IOB|Indian\s+Overseas\s+Bank|UCO|South\s+Indian\s+Bank|Karur\s+Vysya|KVB|DBS|AU|Bandhan|Paytm\s+Payments\s+Bank|Airtel\s+Payments\s+Bank)\b',
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

    // Detect Card vs Account: explicit A/C or account keywords always mean Bank Account, never Credit Card!
    final hasExplicitAccount = lower.contains("a/c") ||
        lower.contains("account") ||
        lower.contains("acct") ||
        lower.contains("bank a/c") ||
        lower.contains("savings") ||
        lower.contains("current");

    final isCreditCard = !hasExplicitAccount &&
        (lower.contains("credit") ||
            (lower.contains("card") && !lower.contains("debit")) ||
            RegExp(r'\bcc\b').hasMatch(lower));
    final isDebitCard = !hasExplicitAccount && lower.contains("debit");

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
    if (RegExp(r'\bhdfc\b').hasMatch(lower)) return "hdfc";
    if (RegExp(r'\bsbi\b').hasMatch(lower) || lower.contains("state bank")) return "sbi";
    if (RegExp(r'\bicici\b').hasMatch(lower)) return "icici";
    if (RegExp(r'\baxis\b').hasMatch(lower)) return "axis";
    if (RegExp(r'\bkotak\b').hasMatch(lower)) return "kotak";
    if (RegExp(r'\brbl\b').hasMatch(lower)) return "rbl";
    if (RegExp(r'\bpnb\b').hasMatch(lower) || lower.contains("punjab")) return "pnb";
    if (RegExp(r'\bcanara\b').hasMatch(lower)) return "canara";
    if (RegExp(r'\bidfc\b').hasMatch(lower)) return "idfc";
    if (RegExp(r'\bbob\b').hasMatch(lower) || lower.contains("baroda") || lower.contains("bank of baroda")) return "bob";
    if (RegExp(r'\bindusind\b').hasMatch(lower)) return "indusind";
    if (RegExp(r'\byes\s+bank\b').hasMatch(lower) || RegExp(r'\byesbank\b').hasMatch(lower)) return "yes";
    if (RegExp(r'\bfederal\b').hasMatch(lower)) return "federal";
    return null;
  }
}
