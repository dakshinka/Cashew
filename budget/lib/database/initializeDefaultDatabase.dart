import 'package:drift/drift.dart' show Value;
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultCategories.dart';

//Initialize default values in database
Future<bool> initializeDefaultDatabase() async {
  //Initialize default categories, but not after a backup load
  if (isDatabaseImportedOnThisSession != true &&
      (await database.getAllCategories()).length <= 0) {
    await createDefaultCategories();
  }

  final existingWallets = await database.getAllWallets();
  if (existingWallets.isEmpty) {
    await database.createOrUpdateWallet(
      defaultWallet(),
      customDateTimeModified: DateTime(0),
    );
  } else {
    // If the default wallet exists but has usd or null, switch to inr
    for (final w in existingWallets) {
      if (w.walletPk == "0" && (w.currency == "usd" || w.currency == null)) {
        await database.createOrUpdateWallet(
          w.copyWith(currency: Value("inr")),
        );
      }
    }
  }
  return true;
}

Future<bool> createDefaultCategories() async {
  print("Creating default categories");
  for (TransactionCategory category in defaultCategories()) {
    try {
      await database.getCategory(category.categoryPk).$2;
    } catch (e) {
      print(
          e.toString() + " default category does not already exist, creating");
      await database.createOrUpdateCategory(category,
          customDateTimeModified: DateTime(0));
    }
  }
  return true;
}

TransactionWallet defaultWallet() {
  return TransactionWallet(
    walletPk: "0",
    name: "default-account-name".tr(),
    dateCreated: DateTime.now(),
    order: 0,
    currency: getDevicesDefaultCurrencyCode(),
    dateTimeModified: null,
    decimals: 2,
    homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
  );
}
