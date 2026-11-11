import 'package:collection/collection.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/categoryManagerHelper.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';

class AiCategorySuggestion {
  final String categoryName;
  final String? categoryPk;
  final String cleanMerchant;
  final double confidence;
  final String? subCategoryName;
  final String? subCategoryPk;

  AiCategorySuggestion({
    required this.categoryName,
    this.categoryPk,
    required this.cleanMerchant,
    required this.confidence,
    this.subCategoryName,
    this.subCategoryPk,
  });
}

class AiCategorizer {
  // Common knowledge base for financial merchant classification
  static final Map<String, List<String>> _categoryKeywords = {
    "Financial & Bank Fees": [
      "finance charge", "finance charges", "offus em int", "offus em prin",
      "offus", "em int", "em prin", "interest charge", "interest charges", "fc @",
      "cgst", "sgst", "igst", "gst on charges", "gst on finance",
      "annual fee", "late payment fee", "card fee", "overlimit fee",
      "forex markup", "processing fee", "smart emi", "merchant emi"
    ],
    "Food & Dining": [
      "swiggy", "zomato", "mcdonald", "starbucks", "burger king", "kfc",
      "domino", "pizza", "subway", "chaayos", "cafe coffee day", "dunkin",
      "taco bell", "haldiram", "biryani", "barbeque", "baker", "sweet",
      "restaurant", "canteen", "dine", "eats", "coffee", "kitchen",
      "tea", "chai", "stall", "dhaba", "bakery", "bhojanalaya", "tiffin",
      "mess", "juice", "darshini", "bhavan", "hotel", "snack", "pan shop",
      "tapri", "cafe", "fast food"
    ],
    "Groceries": [
      "blinkit", "zepto", "instamart", "bigbasket", "dmart", "reliance fresh",
      "smart bazaar", "spencer", "kirana", "supermarket", "provision",
      "nature's basket", "more retail", "grofer", "vegetable", "milk", "dairy"
    ],
    "Transportation": [
      "uber", "ola", "rapido", "irctc", "metro", "petrol", "hpcl", "bpcl",
      "indianoil", "shell", "fuel", "fastag", "toll", "indigo", "air india",
      "vistara", "spicejet", "railway", "train", "flight", "auto", "cab"
    ],
    "Shopping": [
      "amazon", "flipkart", "myntra", "meesho", "ajio", "zara", "h&m", "nike",
      "adidas", "puma", "decathlon", "croma", "reliance digital", "apple",
      "uniqlo", "retail", "fashion", "mall", "store", "jeweller"
    ],
    "Health & Medical": [
      "apollo", "netmeds", "pharmeasy", "1mg", "tata 1mg", "medplus", "practo",
      "pharmacy", "chemist", "hospital", "clinic", "dental", "diagnostic",
      "dr lal", "metropolis", "medic"
    ],
    "Utilities & Bills": [
      "airtel", "jio", "vodafone", "vi ", "bsnl", "bescom", "adani electricity",
      "tata power", "mahadiscom", "gas", "water bill", "broadband", "act fibernet",
      "electricity", "utility", "recharge", "dth", "tata play", "dish tv"
    ],
    "Online Transfer": [
      "transfer", "trf", "vpa", "upi", "enterprises", "traders", "agency", "agencies",
      "services", "online transfer", "neft", "rtgs", "imps", "p2p", "merchant"
    ],
    "Entertainment": [
      "netflix", "spotify", "youtube", "prime video", "disney", "hotstar",
      "bookmyshow", "pvr", "inox", "cinema", "apple.com/bill", "playstation",
      "steam", "gaana", "wynk", "audible"
    ],
    "Income & Salary": [
      "salary", "payroll", "dividend", "interest credited", "cashback",
      "refund", "reimbursement", "incentive", "stipend"
    ],
  };

  /// Cleans raw merchant text (strips state, location, terminal IDs, etc.)
  static String cleanMerchantName(String raw) {
    var clean = raw.trim();

    // Remove common prefixes
    final prefixes = ["VPA ", "UPI/", "UPI-", "UPI - ", "POS ", "AT ", "TO ", "BY "];
    for (final p in prefixes) {
      if (clean.toUpperCase().startsWith(p.toUpperCase())) {
        clean = clean.substring(p.length).trim();
      }
    }

    // Strip common transaction type markers
    final typeMarkers = ["AUTOPAY-", "AUTOPAY ", "MANDATE-", "MANDATE "];
    for (final m in typeMarkers) {
      if (clean.toUpperCase().startsWith(m)) {
        clean = clean.substring(m.length).trim();
      }
    }

    // Strip UPI handle like @okaxis, @okhdfcbank, @paytm, @ybl, @upi
    if (clean.contains('@')) {
      final handle = clean.split('@').first.trim();
      if (handle.length >= 2) {
        clean = handle.replaceAll(RegExp(r'[._]'), ' ');
      }
    }

    // Strip out common noise suffixes
    final noiseSuffixes = [
      RegExp(r'[\s_]+(MUMBAI|BANGALORE|BENGALURU|DELHI|NOIDA|GURGAON|HYDERABAD|CHENNAI|PUNE|KOLKATA|IN|IND)$', caseSensitive: false),
      RegExp(r'[\s_]+(PVT\s*LTD|PRIVATE\s*LIMITED|LIMITED|LTD)$', caseSensitive: false),
      RegExp(r'[\s_]+(RETAIL|STORE|OUTLET|MERCHANT|SERVICES?)$', caseSensitive: false),
      RegExp(r'[\s_]+(ONLINE|PAYMENT|GATEWAY|BILLDESK|RAZORPAY)$', caseSensitive: false),
      RegExp(r'[\s_]+(A\/C|AC|ACC|A|AS|FOR|TO|ON)$', caseSensitive: false),
      RegExp(r'[\s_]*#\d+.*$', caseSensitive: false), // Store numbers like #1234
      RegExp(r'\*.*$'), // Terminal stars like *REST or *TRIP
    ];

    for (final pattern in noiseSuffixes) {
      clean = clean.replaceAll(pattern, '').trim();
    }

    // Capitalize words nicely
    if (clean.isNotEmpty) {
      clean = clean
          .split(' ')
          .where((w) => w.isNotEmpty)
          .map((w) => w.length > 1
              ? '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}'
              : w.toUpperCase())
          .join(' ');
    }

    return clean.isEmpty ? raw : clean;
  }

  /// Convenience alias for suggestCategory
  static Future<AiCategorySuggestion> suggestCategory(String rawTitle, {bool isIncome = false}) {
    return categorize(rawTitle: rawTitle, isIncome: isIncome);
  }

  /// Suggests category and clean title based on user's database and knowledge base
  static Future<AiCategorySuggestion> categorize({
    required String rawTitle,
    required bool isIncome,
  }) async {
    final clean = cleanMerchantName(rawTitle);
    final lowerClean = clean.toLowerCase();

    // 1. Check user's personal past title associations (Highest Priority!)
    try {
      final associated = await database.getSimilarAssociatedTitles(
        title: clean,
        limit: 1,
      );
      if (associated.isNotEmpty) {
        final cat = associated.first.category;
        if (cat.mainCategoryPk != null) {
          final mainCat =
              await database.getCategoryInstance(cat.mainCategoryPk!);
          return AiCategorySuggestion(
            categoryName: mainCat.name,
            categoryPk: mainCat.categoryPk,
            subCategoryName: cat.name,
            subCategoryPk: cat.categoryPk,
            cleanMerchant: clean,
            confidence: 0.99,
          );
        }
        return AiCategorySuggestion(
          categoryName: cat.name,
          categoryPk: cat.categoryPk,
          cleanMerchant: clean,
          confidence: 0.98,
        );
      }
    } catch (_) {}

    // 2. Financial & Bank Fees check (Credit card interest, offus em int, em prin, cgst, sgst, fees)
    if (CategoryManagerHelper.isFinancialOrCardCharge(rawTitle) ||
        CategoryManagerHelper.isFinancialOrCardCharge(clean)) {
      final subCatName = CategoryManagerHelper.getRecommendedSubCategoryName(
          rawTitle.isNotEmpty ? rawTitle : clean);
      final userCategories = await database.getAllCategories();
      final mainCat = userCategories.firstWhereOrNull(
        (c) =>
            c.mainCategoryPk == null &&
            (c.name.toLowerCase() ==
                    CategoryManagerHelper.financialMainCategory.toLowerCase() ||
                c.name.toLowerCase().contains("financial") ||
                c.name.toLowerCase().contains("bank fee") ||
                c.name.toLowerCase() == "bills & fees"),
      );

      String? mainPk;
      String? subPk;
      if (mainCat != null) {
        mainPk = mainCat.categoryPk;
        final subCat = userCategories.firstWhereOrNull(
          (c) =>
              c.mainCategoryPk == mainCat.categoryPk &&
              c.name.toLowerCase() == subCatName.toLowerCase(),
        );
        if (subCat != null) {
          subPk = subCat.categoryPk;
        }
      }

      return AiCategorySuggestion(
        categoryName:
            mainCat?.name ?? CategoryManagerHelper.financialMainCategory,
        categoryPk: mainPk,
        subCategoryName: subCatName,
        subCategoryPk: subPk,
        cleanMerchant: clean,
        confidence: 0.98,
      );
    }

    // 3. Income Check
    if (isIncome) {
      final userCategories = await database.getAllCategories();
      final incomeCat = userCategories.firstWhere(
        (c) => c.income == true,
        orElse: () => userCategories.first,
      );
      return AiCategorySuggestion(
        categoryName: incomeCat.name,
        categoryPk: incomeCat.categoryPk,
        cleanMerchant: clean,
        confidence: 0.92,
      );
    }

    // 4. Match against Knowledge Base
    String matchedCategoryGroup = "Other";
    double highestConfidence = 0.60;

    for (final entry in _categoryKeywords.entries) {
      for (final keyword in entry.value) {
        if (lowerClean.contains(keyword)) {
          matchedCategoryGroup = entry.key;
          highestConfidence = 0.95;
          break;
        }
      }
      if (highestConfidence > 0.8) break;
    }

    // 5. Try LLM classification if knowledge base matched "Other"
    if (matchedCategoryGroup == "Other") {
      try {
        final userCategories = await database.getAllCategories();
        final llmResult = await LlmClassifier.classifyCategoryWithLlm(
          merchant: clean,
          categories: userCategories,
        );
        if (llmResult != null) {
          final matchedPk = llmResult["matchedCategoryPk"]?.toString();
          final matchedSubPk = llmResult["matchedSubCategoryPk"]?.toString();
          final proposedName = llmResult["proposedCategoryName"]?.toString();
          final proposedSub =
              llmResult["proposedSubCategoryName"]?.toString();

          if (matchedPk != null &&
              matchedPk.isNotEmpty &&
              matchedPk != "null") {
            final cat = userCategories.firstWhereOrNull(
              (c) => c.categoryPk == matchedPk,
            );
            if (cat != null) {
              final sub = matchedSubPk != null && matchedSubPk != "null"
                  ? userCategories.firstWhereOrNull(
                      (c) => c.categoryPk == matchedSubPk,
                    )
                  : null;
              return AiCategorySuggestion(
                categoryName: cat.name,
                categoryPk: cat.categoryPk,
                subCategoryName: sub?.name,
                subCategoryPk: sub?.categoryPk,
                cleanMerchant: clean,
                confidence: 0.92,
              );
            }
          } else if (proposedName != null &&
              proposedName.isNotEmpty &&
              proposedName != "null") {
            return AiCategorySuggestion(
              categoryName: proposedName,
              categoryPk: null,
              subCategoryName: proposedSub,
              subCategoryPk: null,
              cleanMerchant: clean,
              confidence: 0.88,
            );
          }
        }
      } catch (_) {}
    }

    // 6. Map matched group to user's actual database category
    String? matchedCategoryPk;
    try {
      final userCategories = await database.getAllCategories();
      final exact = userCategories
          .where((c) =>
              c.name.toLowerCase() == matchedCategoryGroup.toLowerCase())
          .toList();
      if (exact.isNotEmpty) {
        matchedCategoryPk = exact.first.categoryPk;
      } else {
        for (final c in userCategories) {
          final cName = c.name.toLowerCase();
          if (matchedCategoryGroup.toLowerCase().contains(cName) ||
              cName.contains(matchedCategoryGroup.toLowerCase().split(' ')[0])) {
            matchedCategoryPk = c.categoryPk;
            break;
          }
        }
      }
      // Never default to userCategories.first ("Home")! Only default if "Other" category exists.
      if (matchedCategoryPk == null) {
        final otherCat = userCategories.firstWhereOrNull(
          (c) =>
              c.name.toLowerCase() == "other" ||
              c.name.toLowerCase() == "miscellaneous",
        );
        matchedCategoryPk = otherCat?.categoryPk;
      }
    } catch (_) {}

    return AiCategorySuggestion(
      categoryName: matchedCategoryGroup,
      categoryPk: matchedCategoryPk,
      cleanMerchant: clean,
      confidence: highestConfidence,
    );
  }
}
