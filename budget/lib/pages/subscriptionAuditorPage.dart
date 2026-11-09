import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/zombieSubscriptions/subscriptionAuditor.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/textWidgets.dart';

class SubscriptionAuditorPage extends StatefulWidget {
  const SubscriptionAuditorPage({Key? key}) : super(key: key);

  @override
  State<SubscriptionAuditorPage> createState() =>
      _SubscriptionAuditorPageState();
}

class _SubscriptionAuditorPageState extends State<SubscriptionAuditorPage> {
  List<SubscriptionAuditItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAudit();
  }

  Future<void> _loadAudit() async {
    setState(() => _isLoading = true);
    final audit = await SubscriptionAuditor.auditSubscriptions();
    if (mounted) {
      setState(() {
        _items = audit;
        _isLoading = false;
      });
    }
  }

  Future<void> _cancelSubscription(SubscriptionAuditItem item) async {
    openPopup(
      context,
      title: "Cancel Subscription?",
      description:
          "This will cancel recurrence for '${item.name}' so it is no longer billed automatically.",
      icon: Icons.cancel_outlined,
      onSubmitLabel: "Cancel Subscription",
      onSubmit: () async {
        try {
          await database.deleteTransaction(item.subscriptionPk);
          openSnackbar(
            SnackbarMessage(
              title: "Subscription Cancelled",
              description: "${item.name} has been removed from active subscriptions.",
              icon: Icons.check_circle_outline,
            ),
          );
          _loadAudit();
        } catch (e) {
          debugPrint("Error cancelling subscription: $e");
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[appStateSettings["selectedWalletPk"]]?.currency ??
        "";

    final totalAnnualized =
        _items.fold<double>(0.0, (acc, item) => acc + item.annualizedCost);
    final hikesCount =
        _items.where((i) => i.priceIncreasePercent != null).length;
    final zombiesCount = _items.where((i) => i.isZombieCandidate).length;

    return PageFramework(
      title: "Subscription Auditor",
      actions: [
        IconButton(
          tooltip: "Refresh Audit",
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loadAudit,
        ),
      ],
      listWidgets: [
        // Summary Header Card
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: getColor(context, "canvasContainer"),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: getColor(context, "dividerColor").withOpacity(0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.purple.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.auto_awesome_motion_rounded,
                        color: Colors.purple,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const TextFont(
                            text: "Total Annual Commitment",
                            fontSize: 13,
                            textColor: Colors.grey,
                          ),
                          TextFont(
                            text: "$currency${totalAnnualized.toStringAsFixed(0)} / year",
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _MiniBadge(
                      label: "$hikesCount Price Hikes",
                      color: Colors.orange,
                      icon: Icons.trending_up_rounded,
                    ),
                    const SizedBox(width: 8),
                    _MiniBadge(
                      label: "$zombiesCount Inactive Subscriptions",
                      color: Colors.purple,
                      icon: Icons.bedtime_rounded,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(40.0),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60.0, horizontal: 24),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    size: 64,
                    color: Colors.green.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  const TextFont(
                    text: "No Active Subscriptions Found",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  const SizedBox(height: 8),
                  TextFont(
                    text:
                        "Add recurring subscriptions in Cashew to monitor price increases and detect zombie recurring costs.",
                    textAlign: TextAlign.center,
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                ],
              ),
            ),
          )
        else
          ..._items.map((item) => _buildSubscriptionCard(item, currency)).toList(),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildSubscriptionCard(SubscriptionAuditItem item, String currency) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: getColor(context, "canvasContainer"),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: item.priceIncreasePercent != null
                ? Colors.orange.withOpacity(0.5)
                : item.isZombieCandidate
                    ? Colors.purple.withOpacity(0.4)
                    : getColor(context, "dividerColor").withOpacity(0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFont(
                        text: item.name,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      const SizedBox(height: 2),
                      TextFont(
                        text:
                            "Next: ${DateFormat('dd MMM yyyy').format(item.nextDueDate)}",
                        fontSize: 12,
                        textColor: getColor(context, "textLight"),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    TextFont(
                      text: "$currency${item.currentAmount.toStringAsFixed(2)}",
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                    TextFont(
                      text: "≈ $currency${item.annualizedCost.toStringAsFixed(0)}/yr",
                      fontSize: 11,
                      textColor: getColor(context, "textLight"),
                    ),
                  ],
                ),
              ],
            ),

            if (item.alertReason != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: item.priceIncreasePercent != null
                      ? Colors.orange.withOpacity(0.12)
                      : Colors.purple.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      item.priceIncreasePercent != null
                          ? Icons.warning_amber_rounded
                          : Icons.info_outline_rounded,
                      size: 14,
                      color: item.priceIncreasePercent != null
                          ? Colors.orange[800]
                          : Colors.purple,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextFont(
                        text: item.alertReason!,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        textColor: item.priceIncreasePercent != null
                            ? Colors.orange[900]
                            : Colors.purple[900],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Button(
                  label: "Cancel Subscription",
                  icon: Icons.cancel_outlined,
                  color: getColor(context, "dividerColor").withOpacity(0.2),
                  textColor: Colors.redAccent,
                  padding:
                      const EdgeInsetsDirectional.symmetric(horizontal: 12, vertical: 6),
                  fontSize: 12,
                  onTap: () => _cancelSubscription(item),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _MiniBadge({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          TextFont(
            text: label,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            textColor: color,
          ),
        ],
      ),
    );
  }
}
