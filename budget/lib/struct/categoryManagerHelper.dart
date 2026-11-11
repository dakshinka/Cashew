import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart' show Value;
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';

const _uuid = Uuid();

class CategoryManagerHelper {
  static const String financialMainCategory = "Financial & Bank Fees";
  static const String subCatInterest = "Credit Card Interest";
  static const String subCatEmi = "EMI Principal";
  static const String subCatTaxes = "Taxes & GST";
  static const String subCatBankCharges = "Card & Bank Charges";

  /// Checks if a transaction description or narration is a bank fee, card finance charge, EMI, or GST
  static bool isFinancialOrCardCharge(String raw) {
    final lower = raw.toLowerCase();
    return lower.contains("finance charge") ||
        lower.contains("offus em") ||
        lower.contains("offus") ||
        lower.contains("em int") ||
        lower.contains("em prin") ||
        lower.contains("interest charge") ||
        lower.contains("interest on purchase") ||
        lower.contains("fc @") ||
        lower.contains("cgst") ||
        lower.contains("sgst") ||
        lower.contains("igst") ||
        lower.contains("gst on") ||
        lower.contains("late fee") ||
        lower.contains("annual fee") ||
        lower.contains("card fee") ||
        lower.contains("processing fee") ||
        lower.contains("smart emi") ||
        lower.contains("merchant emi");
  }

  /// Maps financial charge raw narration to the ideal subcategory
  static String getRecommendedSubCategoryName(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains("int") ||
        lower.contains("interest") ||
        lower.contains("finance charge") ||
        lower.contains("fc @")) {
      return subCatInterest;
    }
    if (lower.contains("prin") ||
        lower.contains("principal") ||
        lower.contains("emi")) {
      return subCatEmi;
    }
    if (lower.contains("gst") ||
        lower.contains("cgst") ||
        lower.contains("sgst") ||
        lower.contains("igst") ||
        lower.contains("tax")) {
      return subCatTaxes;
    }
    return subCatBankCharges;
  }

  /// Ensures that "Financial & Bank Fees" and its subcategories exist in the user's database.
  /// Prompts user confirmation if [askConfirmation] is true.
  static Future<Map<String, TransactionCategory>?> ensureFinancialCategoriesExist(
    BuildContext context, {
    bool askConfirmation = true,
  }) async {
    final allCategories = await database.getAllCategories();

    // Check if main category already exists
    TransactionCategory? mainCat = allCategories.firstWhereOrNull(
      (c) =>
          c.mainCategoryPk == null &&
          (c.name.toLowerCase() == financialMainCategory.toLowerCase() ||
              c.name.toLowerCase() == "financial fees" ||
              c.name.toLowerCase() == "banking fees"),
    );

    if (mainCat == null && askConfirmation) {
      bool userConfirmed = false;
      await openPopup(
        context,
        title: "Track Financial & Card Fees?",
        description:
            "We detected credit card finance charges, EMI interest/principal, or GST taxes.\n\nWould you like to create the category '$financialMainCategory' with subcategories:\n• $subCatInterest\n• $subCatEmi\n• $subCatTaxes\n• $subCatBankCharges\n\nto track these cleanly instead of mixing them into Home or general expenses?",
        icon: Icons.account_balance_rounded,
        onSubmitLabel: "Create Categories",
        onSubmit: () {
          userConfirmed = true;
          popRoute(context);
        },
        onCancelLabel: "Not Now",
        onCancel: () => popRoute(context),
      );

      if (!userConfirmed) return null;
    }

    // Create main category if missing
    if (mainCat == null) {
      final mainPk = _uuid.v4();
      final newMain = TransactionCategory(
        categoryPk: mainPk,
        name: financialMainCategory,
        colour: toHexString(Colors.indigo),
        iconName: "credit-card.png",
        order: allCategories.length,
        income: false,
        dateCreated: DateTime.now(),
      );
      await database.createOrUpdateCategory(newMain, insert: false);
      mainCat = newMain;
    }

    final refreshedCategories = await database.getAllCategories();
    final existingSubs = refreshedCategories
        .where((c) => c.mainCategoryPk == mainCat!.categoryPk)
        .toList();

    // Helper to get or create subcategory
    Future<TransactionCategory> getOrCreateSub(
        String name, Color color, String icon) async {
      TransactionCategory? sub = existingSubs.firstWhereOrNull(
        (c) => c.name.toLowerCase() == name.toLowerCase(),
      );
      if (sub == null) {
        final newSub = TransactionCategory(
          categoryPk: _uuid.v4(),
          name: name,
          colour: toHexString(color),
          iconName: icon,
          mainCategoryPk: mainCat!.categoryPk,
          order: existingSubs.length,
          income: false,
          dateCreated: DateTime.now(),
        );
        await database.createOrUpdateCategory(newSub, insert: false);
        return newSub;
      }
      return sub;
    }

    final subInterest = await getOrCreateSub(
        subCatInterest, Colors.redAccent, "paper-bill.png");
    final subEmi = await getOrCreateSub(
        subCatEmi, Colors.deepPurple, "bank.png");
    final subTaxes = await getOrCreateSub(
        subCatTaxes, Colors.amber.shade900, "bills.png");
    final subCharges = await getOrCreateSub(
        subCatBankCharges, Colors.blueGrey, "cards.png");

    return {
      'main': mainCat,
      'interest': subInterest,
      'emi': subEmi,
      'taxes': subTaxes,
      'charges': subCharges,
    };
  }

  /// Prompts user confirmation to create a new Category and Subcategory recommended by AI or user
  static Future<Map<String, TransactionCategory>?> askAndCreateCategory(
    BuildContext context, {
    required String categoryName,
    String? subCategoryName,
  }) async {
    bool confirmed = false;
    await openPopup(
      context,
      title: "Add New Category?",
      description:
          "Would you like to create the category '$categoryName'${subCategoryName != null && subCategoryName.isNotEmpty ? " with subcategory '$subCategoryName'" : ""} to categorize this transaction?",
      icon: Icons.category_rounded,
      onSubmitLabel: "Create Category",
      onSubmit: () {
        confirmed = true;
        popRoute(context);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context),
    );

    if (!confirmed) return null;

    final allCategories = await database.getAllCategories();
    TransactionCategory? main = allCategories.firstWhereOrNull(
      (c) =>
          c.mainCategoryPk == null &&
          c.name.toLowerCase() == categoryName.toLowerCase(),
    );

    if (main == null) {
      main = TransactionCategory(
        categoryPk: _uuid.v4(),
        name: categoryName,
        colour: toHexString(Colors.blueGrey),
        iconName: "bills.png",
        order: allCategories.length,
        income: false,
        dateCreated: DateTime.now(),
      );
      await database.createOrUpdateCategory(main, insert: false);
    }

    TransactionCategory? sub;
    if (subCategoryName != null && subCategoryName.isNotEmpty) {
      final refreshed = await database.getAllCategories();
      sub = refreshed.firstWhereOrNull(
        (c) =>
            c.mainCategoryPk == main!.categoryPk &&
            c.name.toLowerCase() == subCategoryName.toLowerCase(),
      );
      if (sub == null) {
        sub = TransactionCategory(
          categoryPk: _uuid.v4(),
          name: subCategoryName,
          colour: toHexString(Colors.teal),
          iconName: "paper-bill.png",
          mainCategoryPk: main.categoryPk,
          order: 0,
          income: false,
          dateCreated: DateTime.now(),
        );
        await database.createOrUpdateCategory(sub, insert: false);
      }
    }

    return {
      'main': main,
      if (sub != null) 'sub': sub,
    };
  }

  /// Prompts user when they change a category/subcategory:
  /// Asks whether to update only this transaction OR all previous and upcoming transactions for this merchant.
  static Future<bool> propagateCategoryChange(
    BuildContext context, {
    required String merchantTitle,
    required String newCategoryPk,
    String? newSubCategoryPk,
    required String newCategoryName,
    String? newSubCategoryName,
  }) async {
    bool applyToAll = false;

    await openPopup(
      context,
      title: "Update Similar Transactions?",
      description:
          "You changed the category for '$merchantTitle' to '$newCategoryName${newSubCategoryName != null ? ' ($newSubCategoryName)' : ''}'.\n\nHow would you like to apply this change?",
      icon: Icons.auto_awesome_rounded,
      onSubmitLabel: "Update Past & Future",
      onSubmit: () {
        applyToAll = true;
        popRoute(context);
      },
      onCancelLabel: "Only This One",
      onCancel: () => popRoute(context),
    );

    if (applyToAll) {
      final cleanTarget = merchantTitle.toLowerCase().trim();
      int updatedCount = 0;

      // 1. Update previous transactions in database
      try {
        final allTxns = await database.allTransactions;
        for (final tx in allTxns) {
          final txName = tx.name.toLowerCase().trim();
          if (txName == cleanTarget ||
              txName.contains(cleanTarget) ||
              cleanTarget.contains(txName)) {
            final updated = tx.copyWith(
              categoryFk: newCategoryPk,
              subCategoryFk: Value(newSubCategoryPk),
            );
            await database.createOrUpdateTransaction(updated, insert: false);
            updatedCount++;
          }
        }
      } catch (e) {
        debugPrint("Error updating past transactions: $e");
      }

      // 2. Lock in association for upcoming SMS and statements
      try {
        final length = await database.getAmountOfAssociatedTitles();
        await database.createOrUpdateAssociatedTitle(
          TransactionAssociatedTitle(
            associatedTitlePk: _uuid.v4(),
            title: merchantTitle.trim(),
            categoryFk: newCategoryPk,
            dateCreated: DateTime.now(),
            order: length,
            isExactMatch: false,
          ),
          insert: false,
        );
      } catch (e) {
        debugPrint("Error creating associated title: $e");
      }

      openSnackbar(
        SnackbarMessage(
          title: "Category Updated",
          description:
              "Updated $updatedCount previous transaction(s) and set rule for future imports.",
          icon: Icons.done_all_rounded,
        ),
      );

      return true;
    }

    return false;
  }
}
