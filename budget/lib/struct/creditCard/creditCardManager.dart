import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:budget/main.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/creditCard/creditCardModels.dart';

class PayoffSimulationScenario {
  final String label;
  final int monthsToPayoff;
  final double monthlyPayment;
  final double totalInterestPaid;
  final double totalAmountPaid;

  PayoffSimulationScenario({
    required this.label,
    required this.monthsToPayoff,
    required this.monthlyPayment,
    required this.totalInterestPaid,
    required this.totalAmountPaid,
  });
}

class CreditCardManager extends ChangeNotifier {
  static final CreditCardManager instance = CreditCardManager._();
  CreditCardManager._();

  static const String _storagePrefix = "credit_card_config_";

  CreditCardConfig getConfig(String walletPk) {
    final str = sharedPreferences.getString("$_storagePrefix$walletPk");
    if (str != null && str.isNotEmpty) {
      try {
        return CreditCardConfig.fromJson(jsonDecode(str));
      } catch (e) {
        debugPrint("Error parsing credit card config: $e");
      }
    }
    return CreditCardConfig(walletPk: walletPk, isEnabled: false);
  }

  Future<void> saveConfig(CreditCardConfig config) async {
    await sharedPreferences.setString(
      "$_storagePrefix${config.walletPk}",
      jsonEncode(config.toJson()),
    );
    notifyListeners();
  }

  /// Simulates payoff timeline and interest cost under different payment scenarios
  static List<PayoffSimulationScenario> runSimulations({
    required double initialBalance,
    required double apr,
    required double minimumDuePercent,
  }) {
    if (initialBalance <= 0) return [];

    final monthlyRate = (apr / 100.0) / 12.0;

    // Scenario 1: Minimum Due Only (e.g. 5% of balance, min $25)
    double balMin = initialBalance;
    double interestMin = 0.0;
    int monthsMin = 0;
    const maxMonths = 360; // 30 year cap
    while (balMin > 1.0 && monthsMin < maxMonths) {
      monthsMin++;
      final interest = balMin * monthlyRate;
      interestMin += interest;
      double payment = (balMin + interest) * (minimumDuePercent / 100.0);
      if (payment < 25.0) payment = 25.0;
      if (payment > balMin + interest) payment = balMin + interest;
      balMin = balMin + interest - payment;
    }

    // Scenario 2: Double Minimum or Fixed Payment
    final double fixedPayment = (initialBalance * 0.10).clamp(50.0, initialBalance);
    double balFixed = initialBalance;
    double interestFixed = 0.0;
    int monthsFixed = 0;
    while (balFixed > 1.0 && monthsFixed < maxMonths) {
      monthsFixed++;
      final interest = balFixed * monthlyRate;
      interestFixed += interest;
      double payment = fixedPayment;
      if (payment > balFixed + interest) payment = balFixed + interest;
      balFixed = balFixed + interest - payment;
    }

    // Scenario 3: Pay in Full (1 Month)
    final double interestFull = 0.0; // Grace period intact

    return [
      PayoffSimulationScenario(
        label: "Pay Minimum Due (${minimumDuePercent.toStringAsFixed(0)}%)",
        monthsToPayoff: monthsMin,
        monthlyPayment: (initialBalance * (minimumDuePercent / 100.0)).clamp(25.0, initialBalance),
        totalInterestPaid: interestMin,
        totalAmountPaid: initialBalance + interestMin,
      ),
      PayoffSimulationScenario(
        label: "Pay Accelerated (10% / Fixed)",
        monthsToPayoff: monthsFixed,
        monthlyPayment: fixedPayment,
        totalInterestPaid: interestFixed,
        totalAmountPaid: initialBalance + interestFixed,
      ),
      PayoffSimulationScenario(
        label: "Pay Full Statement (100%)",
        monthsToPayoff: 1,
        monthlyPayment: initialBalance,
        totalInterestPaid: interestFull,
        totalAmountPaid: initialBalance,
      ),
    ];
  }
}
