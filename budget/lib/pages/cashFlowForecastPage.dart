import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/cashFlow/cashFlowEngine.dart';
import 'package:budget/struct/cashFlow/cashFlowModels.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textWidgets.dart';

class CashFlowForecastPage extends StatefulWidget {
  const CashFlowForecastPage({Key? key}) : super(key: key);

  @override
  State<CashFlowForecastPage> createState() => _CashFlowForecastPageState();
}

class _CashFlowForecastPageState extends State<CashFlowForecastPage> {
  int _forecastDays = 30;
  bool _includeDiscretionaryBurn = true;
  CashFlowForecastSummary? _summary;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadForecast();
  }

  Future<void> _loadForecast() async {
    setState(() => _isLoading = true);
    final summary = await CashFlowEngine.generateForecast(
      daysAhead: _forecastDays,
      includeDiscretionaryBurn: _includeDiscretionaryBurn,
    );
    if (mounted) {
      setState(() {
        _summary = summary;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[appStateSettings["selectedWalletPk"]]?.currency ??
        "";

    return PageFramework(
      title: "Cash Flow Forecaster",
      actions: [
        IconButton(
          tooltip: "Refresh Forecast",
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loadForecast,
        ),
      ],
      listWidgets: [
        // Horizon Selector Pills
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            children: [30, 60, 90].map((days) {
              final isSelected = _forecastDays == days;
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: ChoiceChip(
                  label: TextFont(
                    text: "$days Days",
                    fontSize: 13,
                    textColor: isSelected
                        ? Theme.of(context).colorScheme.onPrimary
                        : getColor(context, "black"),
                  ),
                  selected: isSelected,
                  selectedColor: Theme.of(context).colorScheme.primary,
                  onSelected: (val) {
                    if (val) {
                      setState(() => _forecastDays = days);
                      _loadForecast();
                    }
                  },
                ),
              );
            }).toList(),
          ),
        ),

        // Discretionary Spend Toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: SettingsContainerSwitch(
            title: "Include Daily Discretionary Spend",
            description: "Projects based on your average non-bill spending rate.",
            initialValue: _includeDiscretionaryBurn,
            onSwitched: (val) {
              setState(() => _includeDiscretionaryBurn = val);
              _loadForecast();
            },
          ),
        ),

        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(40.0),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_summary != null) ...[
          // Overdraft Warning if lowest balance is negative
          if (_summary!.hasOverdraftRisk)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.red.withOpacity(0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const TextFont(
                            text: "Overdraft Risk Detected!",
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            textColor: Colors.red,
                          ),
                          const SizedBox(height: 2),
                          TextFont(
                            text:
                                "Projected balance dips to -$currency${_summary!.lowestProjectedBalance.abs().toStringAsFixed(2)} on ${DateFormat('dd MMM').format(_summary!.lowestBalanceDate)}.",
                            fontSize: 12,
                            textColor: Colors.red[800],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Key Metrics Metric Cards
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    title: "Month-End Est.",
                    amount: "$currency${_summary!.projectedEndOfMonthBalance.toStringAsFixed(0)}",
                    color: _summary!.projectedEndOfMonthBalance >= 0
                        ? Colors.green
                        : Colors.red,
                    icon: Icons.calendar_month_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricCard(
                    title: "Safe Daily Spend",
                    amount: "$currency${_summary!.safeDailySpendRemaining.toStringAsFixed(0)}/day",
                    color: Theme.of(context).colorScheme.primary,
                    icon: Icons.shield_rounded,
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    title: "Lowest Balance Dip",
                    amount: "$currency${_summary!.lowestProjectedBalance.toStringAsFixed(0)}",
                    color: _summary!.lowestProjectedBalance >= 0
                        ? Colors.blueGrey
                        : Colors.redAccent,
                    icon: Icons.trending_down_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricCard(
                    title: "Current Liquid Cash",
                    amount: "$currency${_summary!.startingBalance.toStringAsFixed(0)}",
                    color: Colors.teal,
                    icon: Icons.account_balance_wallet_rounded,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextFont(
              text: "Day-by-Day Trajectory",
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),

          // Trajectory List
          ..._summary!.dayPoints.map((point) {
            final isPositive = point.netChange >= 0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: getColor(context, "canvasContainer"),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: getColor(context, "dividerColor").withOpacity(0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        TextFont(
                          text: DateFormat('EEE, dd MMM').format(point.date),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        const Spacer(),
                        TextFont(
                          text: "$currency${point.endingBalance.toStringAsFixed(0)}",
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          textColor: point.endingBalance >= 0
                              ? getColor(context, "black")
                              : Colors.red,
                        ),
                      ],
                    ),
                    if (point.events.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: point.events.map((e) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: e.amount > 0
                                  ? Colors.green.withOpacity(0.12)
                                  : Colors.orange.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: TextFont(
                              text:
                                  "${e.title} (${e.amount > 0 ? '+' : ''}$currency${e.amount.abs().toStringAsFixed(0)})",
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              textColor: e.amount > 0
                                  ? Colors.green[800]
                                  : Colors.orange[900],
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ],

        const SizedBox(height: 40),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String title;
  final String amount;
  final Color color;
  final IconData icon;

  const _MetricCard({
    required this.title,
    required this.amount,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: getColor(context, "canvasContainer"),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: getColor(context, "dividerColor").withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: TextFont(
                  text: title,
                  fontSize: 12,
                  textColor: getColor(context, "textLight"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFont(
            text: amount,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            textColor: color,
          ),
        ],
      ),
    );
  }
}
