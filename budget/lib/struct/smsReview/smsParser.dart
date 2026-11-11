import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:budget/struct/smsReview/reviewModels.dart';
import 'package:budget/struct/smsReview/aiCategorizer.dart';
import 'package:budget/struct/settings.dart';

class ParsedSmsResult {
  final bool success;
  final double amount;
  final String currency;
  final bool isIncome;
  final String rawMerchant;
  final String? accountHint;
  final String? referenceNumber;
  final DateTime date;
  final bool isReminder;

  ParsedSmsResult({
    required this.success,
    this.amount = 0.0,
    this.currency = "₹",
    this.isIncome = false,
    this.rawMerchant = "",
    this.accountHint,
    this.referenceNumber,
    this.isReminder = false,
    DateTime? date,
  }) : date = date ?? DateTime.now();
}

class SmsParser {
  // Regex group that handles standard numbers, Western commas (1,500,000.00), and Indian numbering (1,50,000.00, 15,000)
  // Notice + instead of * ensures numbers without commas/spaces match full digits without truncation!
  static const String _numGroup =
      r'([0-9]{1,3}(?:[,\s][0-9]{2,3})+(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)';

  /// Priority 1 regexes: Amount attached to action words (debited, paid, spent, credited, deposited, salary)
  static final List<RegExp> _actionAmountRegexes = [
    RegExp(
        r'(?:debited\s+by|credited\s+with|credited\s+by|credited\s+for|debited\s+for|is\s+debited\s+by|debited|spent|paid|sent|withdrawn|transferred|deposited|depoisited|credited|salary\s+of|salary\s+credited|salary\s+deposited)\s+(?:(?:Rs\.?|INR|₹|\$|USD|EUR|€|GBP|£)\s*)?' +
            _numGroup +
            r'(?:\s*\/-\s*)?',
        caseSensitive: false),
    RegExp(
        r'(?:(?:Rs\.?|INR|₹|\$|USD|EUR|€|GBP|£)\s*)' +
            _numGroup +
            r'(?:\s*\/-\s*)?\s*(?:debited|spent|paid|sent|credited|deposited|depoisited|received|towards\s+salary)',
        caseSensitive: false),
  ];

  /// Extracts the explicit or inferred transaction currency
  static String extractCurrency(String message) {
    final lower = message.toLowerCase();
    if (RegExp(r'(?:rs\.?|inr|₹)', caseSensitive: false).hasMatch(message) ||
        lower.contains("hdfc") ||
        lower.contains("sbi") ||
        lower.contains("icici") ||
        lower.contains("axis") ||
        lower.contains("kotak") ||
        lower.contains("pnb") ||
        lower.contains("canara") ||
        lower.contains("bank of baroda") ||
        lower.contains("bob ") ||
        lower.contains("upi") ||
        lower.contains("vpa") ||
        lower.contains("paytm") ||
        lower.contains("phonepe") ||
        lower.contains("gpay")) {
      return "₹";
    }
    if (message.contains(r"$") || lower.contains("usd")) {
      return r"$";
    }
    if (message.contains("€") || lower.contains("eur")) {
      return "€";
    }
    if (message.contains("£") || lower.contains("gbp")) {
      return "£";
    }
    if (lower.contains("aed")) {
      return "AED";
    }
    return "₹";
  }

  /// Priority 2 regex: Any currency symbol followed by amount
  static final RegExp _currencyRegex = RegExp(
      r'(?:(?:Rs\.?|INR|₹|\$|USD|EUR|€|GBP|£)\s*)' + _numGroup + r'(?:\s*\/-\s*)?',
      caseSensitive: false);

  /// Keywords indicating income/credit
  static final List<String> _incomeKeywords = [
    "credited",
    "received",
    "deposited",
    "depoisited",
    "refund",
    "salary",
    "cashback",
    "added to",
    "payment received",
  ];

  /// Keywords indicating expense/debit
  static final List<String> _expenseKeywords = [
    "debited",
    "spent",
    "paid",
    "sent",
    "deducted",
    "withdrawn",
    "purchase",
    "charged",
    "used",
    "trf to",
  ];

  /// Anti-spam / Advertisement keywords to reject marketing & promo messages
  static final List<String> _advertisementKeywords = [
    "pre-approved",
    "pre approved",
    "apply now",
    "congratulations",
    "offer valid",
    "get up to",
    "cashback of up to",
    "discount of up to",
    "click here",
    "avail loan",
    "chance to win",
    "reward points expire",
    "upgrade your card",
    "special offer",
    "flat rs",
    "use promo code",
    "use coupon",
    "win cash",
    "voucher",
    "claim now",
    "expires on",
    "exclusive offer",
    "hurry",
    "limited period",
    "instant loan",
    "zero interest",
    "zero processing fee",
    "credit limit increase",
  ];

  /// Balance inquiry keywords (only stating balance, not a new transaction)
  static final List<String> _balanceOnlyKeywords = [
    "available balance is",
    "avl bal is",
    "avl bal in",
    "available bal is",
    "clear balance is",
    "effective balance is",
    "balance in your account",
    "bal in a/c is",
    "ledger balance is",
    "current balance is",
  ];

  /// Informational banking & regulatory notification keywords (not transactions)
  static final List<String> _informationKeywords = [
    "e-mandate",
    "mandate",
    "will be deducted",
    "will be debited",
    "will be charged",
    "scheduled to be",
    "scheduled on",
    "scheduled for",
    "auto-debit scheduled",
    "autopay scheduled",
    "standing instruction",
    "si scheduled",
    "kyc",
    "service request",
    "ticket no",
    "sr no",
    "statement generated",
    "e-statement",
    "account statement",
    "mandate registered",
    "e-mandate created",
    "autopay set up",
    "autopay setup",
    "beneficiary added",
    "payee added",
    "cheque book",
    "cheque deposited",
    "cheque returned",
    "transaction declined",
    "transaction failed",
    "failed transaction",
    "insufficient funds",
    "card dispatched",
    "pin generated",
    "daily limit",
    "upi transaction limit",
    "reward points",
    "points credited",
    "points balance",
    "a/c linked to",
    "pan updated",
    "address updated",
  ];

  /// Bill reminder & upcoming due date keywords
  static final List<String> _reminderKeywords = [
    "reminder",
    "bill due",
    "payment due",
    "due on",
    "due by",
    "pay before",
    "minimum amount due",
    "total amount due",
    "upcoming bill",
    "bill generated",
    "overdue by",
    "payment reminder",
    "bill reminder",
    "please pay",
    "is due for",
  ];

  /// Extracts clean account type and identity (e.g. "HDFC A/C *4340", "Cash", "RBL Credit Card *9547")
  static String? extractAccountHint(String message, {double? amount}) {
    final lower = message.toLowerCase();

    // 1. ATM / Cash Withdrawal detection
    if (lower.contains("atm") ||
        lower.contains("cash withdrawal") ||
        lower.contains("cash w/d") ||
        lower.contains("withdrawn from atm")) {
      return "Cash";
    }

    // 2. Bank name detection
    // Prioritize the payment/account clause introduced by "on", "from", "using", "via", "with"
    // (e.g. "on RBL Bank credit card (9547)", "From HDFC Bank A/C *4340")
    String? bankName;
    final bankRegex = RegExp(
      r'\b(HDFC(?:\s+Bank)?|SBI|State\s+Bank\s+of\s+India|ICICI(?:\s+Bank)?|Axis(?:\s+Bank)?|Kotak(?:\s+Bank)?|PNB|Punjab\s+National\s+Bank|Canara(?:\s+Bank)?|Bank\s+of\s+Baroda|BOB|IDFC(?:\s+FIRST(?:\s+Bank)?)?|IndusInd(?:\s+Bank)?|Yes\s+Bank|YES|Federal\s+Bank|Standard\s+Chartered|Citi(?:bank)?|HSBC|RBL(?:\s+Bank)?|Union\s+Bank(?:\s+of\s+India)?|Indian\s+Bank|BOI|Bank\s+of\s+India|Central\s+Bank(?:\s+of\s+India)?|IOB|Indian\s+Overseas\s+Bank|UCO(?:\s+Bank)?|South\s+Indian\s+Bank|Karur\s+Vysya(?:\s+Bank)?|KVB|DBS(?:\s+Bank)?|AU(?:\s+Small\s+Finance\s+Bank)?|Bandhan(?:\s+Bank)?|Paytm\s+Payments\s+Bank|Airtel\s+Payments\s+Bank)\b',
      caseSensitive: false,
    );

    final clauseRegex = RegExp(
      r'\b(?:on|from|using|via|with|through|in|into|to)\s+([^.]+)',
      caseSensitive: false,
    );
    final clauseMatches = clauseRegex.allMatches(message);
    for (final cm in clauseMatches) {
      final clause = cm.group(1);
      if (clause != null) {
        final bMatch = bankRegex.firstMatch(clause);
        if (bMatch != null) {
          bankName = bMatch.group(0)?.trim();
          break;
        }
      }
    }

    // Fallback: search whole message if not found in on/from clause
    if (bankName == null) {
      final bankMatch = bankRegex.firstMatch(message);
      if (bankMatch != null) {
        bankName = bankMatch.group(0)?.trim();
      }
    }

    // 3. Card vs Account
    final hasExplicitAccount = lower.contains("a/c") ||
        lower.contains("account") ||
        lower.contains("acct") ||
        lower.contains("bank a/c") ||
        lower.contains("savings") ||
        lower.contains("current");

    final isCreditCard = !hasExplicitAccount &&
        (lower.contains("credit card") ||
            lower.contains("card ending") ||
            lower.contains("creditcard") ||
            RegExp(r'\bcc\b').hasMatch(lower));
    final isDebitCard = !hasExplicitAccount &&
        (lower.contains("debit card") || lower.contains("debitcard"));

    // 4. Digits / Account Number extraction
    // Must be preceded by account or card keywords, or in parentheses after card/account, or explicitly masked.
    // Never match the transaction amount!
    final accountKeywordRegex = RegExp(
      r'(?:a/c|ac|account|acct|acc|card)\s*(?:no\.?|number|ending(?:\s*in|\s*with)?|\s*[:.\-]*\s*)*\s*\(?([xX*.]*\d{3,6})\)?',
      caseSensitive: false,
    );

    String? digits;
    double? amt = amount;
    if (amt == null || amt <= 0) {
      amt = extractAmountFromText(message);
    }
    final amountInt = amt != null && amt > 0 ? amt.toInt() : null;

    final matches = accountKeywordRegex.allMatches(message);
    for (final m in matches) {
      final cand = m.group(1);
      if (cand != null && cand.isNotEmpty) {
        final cleaned = cand.replaceAll(RegExp(r'[^\dxX*]'), '');
        final numericOnly = cleaned.replaceAll(RegExp(r'\D'), '');
        if (amountInt != null &&
            (numericOnly == amountInt.toString() ||
                (amt != null && numericOnly == amt.toStringAsFixed(0)))) {
          continue; // Skip if it collides with transaction amount
        }
        digits = cleaned;
        break;
      }
    }

    // If not found yet, check for explicitly masked numbers (e.g. *4340, XX1234)
    if (digits == null) {
      final maskedNumRegex = RegExp(
        r'\b([xX*]{1,6}\d{3,6})\b',
        caseSensitive: false,
      );
      final maskedMatch = maskedNumRegex.firstMatch(message);
      if (maskedMatch != null) {
        final cand = maskedMatch.group(1);
        final numericOnly = cand?.replaceAll(RegExp(r'\D'), '') ?? '';
        if (amountInt == null ||
            (numericOnly != amountInt.toString() &&
                (amt == null || numericOnly != amt.toStringAsFixed(0)))) {
          digits = cand;
        }
      }
    }

    // Normalize bank name display (e.g. "HDFC Bank" -> "HDFC", "RBL Bank" -> "RBL")
    String? displayBank = bankName;
    if (displayBank != null) {
      displayBank = displayBank
          .replaceFirst(RegExp(r'\s+Bank$', caseSensitive: false), '')
          .trim();
    }

    final cleanDigits = digits != null
        ? (digits.startsWith('*') || digits.toLowerCase().startsWith('x')
            ? digits
            : '*$digits')
        : null;

    if (displayBank != null && isCreditCard) {
      return "$displayBank Credit Card${cleanDigits != null ? ' $cleanDigits' : ''}";
    } else if (displayBank != null && isDebitCard) {
      return "$displayBank Debit Card${cleanDigits != null ? ' $cleanDigits' : ''}";
    } else if (displayBank != null && cleanDigits != null) {
      return "$displayBank A/C $cleanDigits";
    } else if (displayBank != null) {
      return "$displayBank Bank";
    } else if (isCreditCard && cleanDigits != null) {
      return "Credit Card $cleanDigits";
    } else if (isCreditCard) {
      return "Credit Card";
    } else if (cleanDigits != null) {
      return "A/C $cleanDigits";
    }

    return null;
  }

  /// Regex for reference / UTR / UPI Ref
  static final RegExp _refRegex = RegExp(
    r'(?:ref(?:\s*no)?|utr|upi\s*ref(?:no)?)\s*[:.]?\s*([A-Za-z0-9]+)',
    caseSensitive: false,
  );

  /// Month lookup helper
  static int monthNumber(String name) => _monthNumber(name);
  static int _monthNumber(String name) {
    final lower = name.toLowerCase();
    const months = {
      "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    };
    for (final key in months.keys) {
      if (lower.startsWith(key)) return months[key]!;
    }
    return DateTime.now().month;
  }

  /// Extracts exact transaction date from SMS text
  static DateTime extractDate(String message) {
    final now = DateTime.now();
    try {
      // Format 1: DD-MM-YYYY or DD/MM/YYYY or DD-MM-YY or DD/MM/YY or DD.MM.YYYY
      // e.g. "on 04-11-26", "on 04/11/2026", "04-11-2026"
      final numericDateRegex = RegExp(
        r'\b([0-3]?[0-9])[-/.]([0-1]?[0-9])[-/.](20[2-9][0-9]|[2-9][0-9])\b',
      );
      final numMatch = numericDateRegex.firstMatch(message);
      if (numMatch != null) {
        int day = int.parse(numMatch.group(1)!);
        int month = int.parse(numMatch.group(2)!);
        int year = int.parse(numMatch.group(3)!);
        if (year < 100) year += 2000;
        if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
          int hour = _extractHour(message) ?? now.hour;
          int minute = _extractMinute(message) ?? now.minute;
          return DateTime(year, month, day, hour, minute);
        }
      }

      // Format 2: DD-MMM-YY or DD-MMM-YYYY or DD MMM YYYY or DD-MMM
      // e.g. "04-Nov-26", "04-Nov-2026", "04 Nov 2026"
      final alphaDateRegex = RegExp(
        r'\b([0-3]?[0-9])[-/ ](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/ ]?(20[2-9][0-9]|[2-9][0-9])?\b',
        caseSensitive: false,
      );
      final alphaMatch = alphaDateRegex.firstMatch(message);
      if (alphaMatch != null) {
        int day = int.parse(alphaMatch.group(1)!);
        int month = _monthNumber(alphaMatch.group(2)!);
        int year = now.year;
        if (alphaMatch.group(3) != null) {
          year = int.parse(alphaMatch.group(3)!);
          if (year < 100) year += 2000;
        }
        if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
          int hour = _extractHour(message) ?? now.hour;
          int minute = _extractMinute(message) ?? now.minute;
          return DateTime(year, month, day, hour, minute);
        }
      }

      // Format 3: MMM DD, YYYY e.g. "Nov 04, 2026"
      final mmmDdRegex = RegExp(
        r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+([0-3]?[0-9])(?:st|nd|rd|th)?,?\s*(20[2-9][0-9]|[2-9][0-9])?\b',
        caseSensitive: false,
      );
      final mmmDdMatch = mmmDdRegex.firstMatch(message);
      if (mmmDdMatch != null) {
        int month = _monthNumber(mmmDdMatch.group(1)!);
        int day = int.parse(mmmDdMatch.group(2)!);
        int year = now.year;
        if (mmmDdMatch.group(3) != null) {
          year = int.parse(mmmDdMatch.group(3)!);
          if (year < 100) year += 2000;
        }
        if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
          int hour = _extractHour(message) ?? now.hour;
          int minute = _extractMinute(message) ?? now.minute;
          return DateTime(year, month, day, hour, minute);
        }
      }

      // Format 4: ISO YYYY-MM-DD
      final isoRegex = RegExp(r'\b(20[2-9][0-9])[-/.]([0-1]?[0-9])[-/.]([0-3]?[0-9])\b');
      final isoMatch = isoRegex.firstMatch(message);
      if (isoMatch != null) {
        int year = int.parse(isoMatch.group(1)!);
        int month = int.parse(isoMatch.group(2)!);
        int day = int.parse(isoMatch.group(3)!);
        if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
          int hour = _extractHour(message) ?? now.hour;
          int minute = _extractMinute(message) ?? now.minute;
          return DateTime(year, month, day, hour, minute);
        }
      }
    } catch (_) {}

    return now;
  }

  static final RegExp _timeRegex = RegExp(
    r'\b([0-2]?[0-9]):([0-5][0-9])(?::([0-5][0-9]))?\s*(am|pm|hrs)?\b',
    caseSensitive: false,
  );

  static int? _extractHour(String message) {
    final m = _timeRegex.firstMatch(message);
    if (m != null) {
      int h = int.parse(m.group(1)!);
      final amPm = m.group(4)?.toLowerCase();
      if (amPm == "pm" && h < 12) h += 12;
      if (amPm == "am" && h == 12) h = 0;
      if (h >= 0 && h <= 23) return h;
    }
    return null;
  }

  static int? _extractMinute(String message) {
    final m = _timeRegex.firstMatch(message);
    if (m != null) {
      int min = int.parse(m.group(2)!);
      if (min >= 0 && min <= 59) return min;
    }
    return null;
  }

  /// Determines whether a string is a valid merchant name (not user's name, card number, or noise)
  static bool _isValidMerchant(String candidate) {
    if (candidate.length < 2) return false;
    final lower = candidate.toLowerCase().trim();

    // Ignore account numbers, card indicators, balance tokens
    if (lower.contains("card ending") ||
        lower.contains("avl bal") ||
        lower.contains("avail bal") ||
        lower.contains("bank ac") ||
        lower.contains("a/c no") ||
        lower.contains("account no") ||
        lower.contains("debited") ||
        lower.contains("credited") ||
        lower.contains("ref no") ||
        lower.contains("upi ref") ||
        lower == "your account" ||
        lower == "customer" ||
        lower == "user" ||
        lower == "dear customer" ||
        lower == "cardholder") {
      return false;
    }

    // Ignore if candidate is purely numbers or punctuation
    if (RegExp(r'^[0-9\s.,\-_]+$').hasMatch(candidate)) {
      return false;
    }

    // Filter out user's own name if available in app settings
    final userName = appStateSettings["username"]?.toString().trim().toLowerCase();
    if (userName != null && userName.length >= 3 && lower == userName) {
      return false;
    }

    return true;
  }

  /// Checks whether a message is an informational notice, future mandate reminder, or regulatory notification
  static bool isInformationalOrFutureNotice(String message) {
    final lower = message.toLowerCase();

    // Future deduction / e-mandate / upcoming scheduled notices
    if (lower.contains("e-mandate") ||
        lower.contains("mandate") ||
        lower.contains("will be deducted") ||
        lower.contains("will be debited") ||
        lower.contains("will be charged") ||
        lower.contains("scheduled to be") ||
        lower.contains("scheduled on") ||
        lower.contains("scheduled for") ||
        lower.contains("auto-debit scheduled") ||
        lower.contains("autopay scheduled") ||
        lower.contains("standing instruction") ||
        lower.contains("si scheduled") ||
        lower.contains("mandate registered") ||
        lower.contains("e-mandate created") ||
        lower.contains("autopay set up") ||
        lower.contains("autopay setup")) {
      return true;
    }

    // Check non-transaction banking alerts
    for (final info in _informationKeywords) {
      if (lower.contains(info)) {
        if (!lower.contains("has been debited") &&
            !lower.contains("is debited by") &&
            !lower.contains("debited for rs") &&
            !lower.contains("debited with") &&
            !lower.contains("deposited") &&
            !lower.contains("depoisited") &&
            !lower.contains("credited") &&
            !lower.contains("salary")) {
          return true;
        }
      }
    }

    return false;
  }

  /// Extracts the genuine payee / merchant, handling UPI trade names and removing user salutations
  static String extractMerchant(String message, {bool isCredit = false}) {
    // 1. Strip salutations at start of message so user's greeting name is never mistaken for payee
    // e.g. "Dear Kamaraj," or "Dear Customer," or "Hi John:"
    String cleaned = message.replaceAll(
      RegExp(r'^(?:Dear|Hi|Hello)\s+[A-Za-z0-9_.\- ]+?[,:]\s*', caseSensitive: false),
      '',
    );

    // 2. Salary detection
    final lowerCleaned = cleaned.toLowerCase();
    if (lowerCleaned.contains("salary")) {
      final ftPatt = RegExp(
        r'for\s+FT\s*[-:\d\s*X]+-\s*([A-Za-z0-9&.\-_ ]+?)(?:\.\s*Avl|\s+Avl|\s*\(|\s*\.|\s*,|\s*$)',
        caseSensitive: false,
      );
      final ftMatch = ftPatt.firstMatch(cleaned);
      if (ftMatch != null && ftMatch.group(1) != null && _isValidMerchant(ftMatch.group(1)!)) {
        return ftMatch.group(1)!.trim();
      }

      final salaryPatt = RegExp(
        r'(?:by\s+salary(?:\s*[-/:]?\s*|\s+from\s+)|\bsalary\s+from\s+)([A-Za-z0-9&.\-_ ]+?)(?:\s+on\b|\s+ref\b|\s+avail\b|\s*\(|\s*\.|\s*,|\s*$)',
        caseSensitive: false,
      );
      final m = salaryPatt.firstMatch(cleaned);
      if (m != null && m.group(1) != null && _isValidMerchant(m.group(1)!)) {
        return m.group(1)!.trim();
      }
      return "Salary";
    }

    // 3. Check for UPI parenthesized trade name
    // e.g. "to VPA teashop@upi (RAMESH TEA STALL)" or "to 9876543210@paytm (Chai Point)"
    final parenRegex = RegExp(
      r'(?:to|at|vpa|paid to)\s+[^,(]+\(([^)]+)\)',
      caseSensitive: false,
    );
    final parenMatch = parenRegex.firstMatch(cleaned);
    if (parenMatch != null && parenMatch.groupCount >= 1) {
      final inside = parenMatch.group(1)!.trim();
      if (_isValidMerchant(inside)) {
        return inside;
      }
    }

    // 4. Priority patterns for payment recipients
    final patterns = [
      // "paid to <merchant>", "sent to <merchant>", "transferred to <merchant>", "trf to <merchant>"
      RegExp(r'(?:paid to|sent to|transferred to|trf to)\s+([A-Za-z0-9&.\-_ ]+?)(?:\s+on\b|\s+ref\b|\s+upi\b|\s+via\b|\s+using\b|\s+a/c\b|\s+ac\b|\s+as\b|\s+for\b|\s+from\b|\s+bal\b|\s*\(|\s*\.|\s*,|\s*$)', caseSensitive: false),
      // "at <merchant>"
      RegExp(r'(?:at\s+)([A-Za-z0-9&.\-_ ]+?)(?:\s+on\b|\s+ref\b|\s+upi\b|\s+via\b|\s+using\b|\s+a/c\b|\s+ac\b|\s+as\b|\s+for\b|\s+from\b|\s+bal\b|\s*\(|\s*\.|\s*,|\s*$)', caseSensitive: false),
      // "to <merchant>" (avoiding "to A/c" or "to your account")
      RegExp(r'(?:to\s+)(?!(?:a/c|ac|account|your\s+account))([A-Za-z0-9&.\-_ ]+?)(?:\s+on\b|\s+ref\b|\s+upi\b|\s+via\b|\s+using\b|\s+a/c\b|\s+ac\b|\s+as\b|\s+for\b|\s+from\b|\s+bal\b|\s*\(|\s*\.|\s*,|\s*$)', caseSensitive: false),
      // "credited by / received from <sender>"
      RegExp(r'(?:credited by|received from)\s+([A-Za-z0-9&.\-_ ]+?)(?:\s+on\b|\s+ref\b|\s+upi\b|\s+via\b|\s*\.|\s*,|\s*$)', caseSensitive: false),
      // "VPA <vpa_address>"
      RegExp(r'(?:vpa\s+)([A-Za-z0-9&.\-_@]+)', caseSensitive: false),
      // "info: <merchant>"
      RegExp(r'(?:info|narration|desc)[:\s]+([A-Za-z0-9&.\-_ ]+?)(?:\s+on\b|\s+ref\b|\s*\.|\s*,|\s*$)', caseSensitive: false),
    ];

    for (final reg in patterns) {
      final match = reg.firstMatch(cleaned);
      if (match != null && match.groupCount >= 1) {
        final candidate = match.group(1)!.trim();
        if (_isValidMerchant(candidate)) {
          return candidate;
        }
      }
    }

    if (isCredit && lowerCleaned.contains("salary")) {
      return "Salary";
    }

    return isCredit ? "Income Transfer" : "Bank Transfer";
  }

  /// Extracts the full transacted amount, supporting Indian numbering (e.g. 1,50,000.00),
  /// while ignoring non-transaction numbers such as available balance or credit limits.
  static double? extractAmountFromText(String message) {
    // 1. Priority 1: Match attached to explicit debit/credit/paid action word
    for (final reg in _actionAmountRegexes) {
      final match = reg.firstMatch(message);
      if (match != null && match.groupCount >= 1) {
        final clean = match.group(1)!.replaceAll(RegExp(r'[, ]'), '').trim();
        final val = double.tryParse(clean);
        if (val != null && val > 0) return val;
      }
    }

    // 2. Priority 2: Look at all currency occurrences, skipping any that are balance / limit numbers
    for (final match in _currencyRegex.allMatches(message)) {
      final startIdx = match.start;
      final prefix = message
          .substring(startIdx > 35 ? startIdx - 35 : 0, startIdx)
          .toLowerCase();
      if (prefix.contains("bal") ||
          prefix.contains("balance") ||
          prefix.contains("avl") ||
          prefix.contains("available") ||
          prefix.contains("limit") ||
          prefix.contains("clear") ||
          prefix.contains("ledger") ||
          prefix.contains("total bal")) {
        continue;
      }
      final clean = match.group(1)!.replaceAll(RegExp(r'[, ]'), '').trim();
      final val = double.tryParse(clean);
      if (val != null && val > 0) return val;
    }

    return null;
  }

  /// Checks user-learned / AI-synthesized regex patterns stored in local persistent settings
  static ParsedSmsResult? _checkCustomLearnedPatterns(String message) {
    try {
      final raw = appStateSettings["customSmsPatterns"];
      if (raw == null) return null;
      List patternsList = [];
      if (raw is List) {
        patternsList = raw;
      } else if (raw is String && raw.trim().isNotEmpty) {
        patternsList = jsonDecode(raw);
      }
      for (final p in patternsList) {
        if (p is! Map) continue;
        final patternStr = p["pattern"]?.toString();
        if (patternStr == null || patternStr.isEmpty) continue;
        final reg = RegExp(patternStr, caseSensitive: false);
        final match = reg.firstMatch(message);
        if (match != null) {
          final amtGroup =
              p["amountGroup"] is int ? p["amountGroup"] as int : 1;
          final merGroup =
              p["merchantGroup"] is int ? p["merchantGroup"] as int : 2;
          final isIncome = p["isIncome"] == true;

          double? amt;
          if (match.groupCount >= amtGroup && match.group(amtGroup) != null) {
            final clean =
                match.group(amtGroup)!.replaceAll(RegExp(r'[, ]'), '').trim();
            amt = double.tryParse(clean);
          }
          amt ??= extractAmountFromText(message);
          if (amt != null && amt > 0) {
            String merchant = "";
            if (match.groupCount >= merGroup &&
                match.group(merGroup) != null) {
              merchant = match.group(merGroup)!.trim();
            }
            if (merchant.isEmpty || !_isValidMerchant(merchant)) {
              merchant = extractMerchant(message, isCredit: isIncome);
            }
            return ParsedSmsResult(
              success: true,
              amount: amt,
              currency: extractCurrency(message),
              isIncome: isIncome,
              rawMerchant: merchant,
              accountHint: extractAccountHint(message, amount: amt),
              date: extractDate(message),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Custom regex check error: $e");
    }
    return null;
  }

  /// Adds a verified regex pattern to local storage so future SMS of this format are parsed 100% offline
  static Future<bool> addLearnedPattern({
    required String pattern,
    required int amountGroup,
    int? merchantGroup,
    required bool isIncome,
    String? exampleSms,
  }) async {
    try {
      final raw = appStateSettings["customSmsPatterns"];
      List patternsList = [];
      if (raw is List) {
        patternsList = List.from(raw);
      } else if (raw is String && raw.trim().isNotEmpty) {
        patternsList = List.from(jsonDecode(raw));
      }

      final exists =
          patternsList.any((p) => p is Map && p["pattern"] == pattern);
      if (!exists) {
        patternsList.add({
          "pattern": pattern,
          "amountGroup": amountGroup,
          "merchantGroup": merchantGroup,
          "isIncome": isIncome,
          "example": exampleSms ?? "",
          "createdAt": DateTime.now().toIso8601String(),
        });
        await updateSettings(
            "customSmsPatterns", jsonEncode(patternsList),
            updateGlobalState: true);
        debugPrint("Saved new offline regex pattern: $pattern");
        return true;
      }
    } catch (e) {
      debugPrint("Failed to save learned pattern: $e");
    }
    return false;
  }

  /// Parse an incoming SMS or notification message
  static ParsedSmsResult parse(String message) {
    if (message.trim().isEmpty) {
      return ParsedSmsResult(success: false);
    }

    // 0. Check AI-synthesized / user-learned persistent offline regex patterns first
    final customMatch = _checkCustomLearnedPatterns(message);
    if (customMatch != null) {
      return customMatch;
    }

    final lower = message.toLowerCase();

    // 1. Strict OTP & Security check
    if (lower.contains("otp") ||
        lower.contains("verification code") ||
        lower.contains("do not share")) {
      return ParsedSmsResult(success: false);
    }

    // 2. Strict Information & Future Notice / E-Mandate check
    if (isInformationalOrFutureNotice(message)) {
      return ParsedSmsResult(success: false);
    }

    // 3. Strict Advertisement check
    for (final ad in _advertisementKeywords) {
      if (lower.contains(ad)) {
        if (!lower.contains("has been debited") &&
            !lower.contains("is debited by") &&
            !lower.contains("debited for rs")) {
          return ParsedSmsResult(success: false);
        }
      }
    }

    // 4. Strict Balance Inquiry check (Messages that only report balance)
    for (final bal in _balanceOnlyKeywords) {
      if (lower.contains(bal)) {
        if (!lower.contains("debited") &&
            !lower.contains("credited") &&
            !lower.contains("spent") &&
            !lower.contains("sent") &&
            !lower.contains("paid")) {
          return ParsedSmsResult(success: false);
        }
      }
    }

    // 5. Detect bill reminders (to track with check required)
    bool isReminder = false;
    for (final rem in _reminderKeywords) {
      if (lower.contains(rem)) {
        isReminder = true;
        break;
      }
    }

    // 6. Determine debit vs credit
    bool isCredit = false;
    for (final kw in _incomeKeywords) {
      if (lower.contains(kw)) {
        isCredit = true;
        break;
      }
    }

    // Exclude future notices like "will be deducted", "will be debited", "e-mandate"
    final isFutureNotice = lower.contains("will be") ||
        lower.contains("scheduled to") ||
        lower.contains("e-mandate") ||
        lower.contains("standing instruction");

    bool isDebit = false;
    if (!isFutureNotice) {
      for (final kw in _expenseKeywords) {
        if (lower.contains(kw)) {
          isDebit = true;
          break;
        }
      }
    }

    // Must be either debit, credit, or a reminder message
    if (!isCredit && !isDebit && !isReminder) {
      return ParsedSmsResult(success: false);
    }

    // Extract complete amount (supporting Indian formatting)
    final extractedAmount = extractAmountFromText(message);
    if (extractedAmount == null || extractedAmount <= 0) {
      return ParsedSmsResult(success: false);
    }

    // Extract genuine merchant
    final rawMerchant = extractMerchant(message, isCredit: isCredit && !isDebit);

    // Extract account hint
    final accountHint = extractAccountHint(message, amount: extractedAmount);

    // Extract reference number
    String? refNo;
    final refMatch = _refRegex.firstMatch(message);
    if (refMatch != null && refMatch.groupCount >= 1) {
      refNo = refMatch.group(1)?.trim();
    }

    // Extract exact date
    final exactDate = extractDate(message);

    // Extract currency
    final currency = extractCurrency(message);

    return ParsedSmsResult(
      success: true,
      amount: extractedAmount,
      currency: currency,
      isIncome: isCredit && !isDebit,
      rawMerchant: rawMerchant,
      accountHint: accountHint,
      referenceNumber: refNo,
      date: exactDate,
      isReminder: isReminder,
    );
  }

  /// Splits a multi-SMS pasted block into individual SMS strings
  static List<String> splitBatchMessages(String multiTextMessage) {
    final raw = multiTextMessage.trim();
    if (raw.isEmpty) return [];

    // Check if separated by --- or double newlines
    if (raw.contains("---")) {
      return raw.split(RegExp(r'\s*---+\s*')).where((s) => s.trim().isNotEmpty).toList();
    }

    final doubleNewlineChunks = raw.split(RegExp(r'\n\s*\n+'));
    if (doubleNewlineChunks.length > 1) {
      return doubleNewlineChunks.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }

    // Otherwise return single message
    return [raw];
  }

  /// Converts a parsed result into a full ReviewTransaction using AI Categorizer
  static Future<ReviewTransaction> createReviewTransaction(
      String rawMessage, {DateTime? overrideDate}) async {
    final parsed = parse(rawMessage);

    final cleanTitle = AiCategorizer.cleanMerchantName(parsed.rawMerchant);
    final aiSuggestion = await AiCategorizer.categorize(
      rawTitle: parsed.rawMerchant.isNotEmpty ? parsed.rawMerchant : cleanTitle,
      isIncome: parsed.isIncome,
    );

    return ReviewTransaction(
      rawMessage: rawMessage,
      extractedTitle: parsed.rawMerchant,
      cleanMerchant: cleanTitle,
      amount: parsed.amount,
      currency: parsed.currency,
      date: overrideDate ?? parsed.date,
      isIncome: parsed.isIncome,
      suggestedCategoryName: aiSuggestion.categoryName,
      suggestedCategoryPk: aiSuggestion.categoryPk,
      suggestedSubCategoryName: aiSuggestion.subCategoryName,
      suggestedSubCategoryPk: aiSuggestion.subCategoryPk,
      confidence: aiSuggestion.confidence,
      accountHint: parsed.accountHint,
      isReminder: parsed.isReminder,
    );
  }
}
