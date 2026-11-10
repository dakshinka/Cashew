import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:budget/colors.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/struct/smsReview/smsDiagnosticTracker.dart';
import 'package:budget/struct/smsReview/smsParser.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/smsInboxScanner.dart';

class SmsInspectorPage extends StatefulWidget {
  const SmsInspectorPage({Key? key}) : super(key: key);

  @override
  State<SmsInspectorPage> createState() => _SmsInspectorPageState();
}

class _SmsInspectorPageState extends State<SmsInspectorPage> {
  String _selectedFilter = "all"; // all, captured, other_sms, skipped, duplicate
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    SmsDiagnosticTracker.instance.init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _testAiOnMessage(String rawMessage) async {
    openBottomSheet(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: FutureBuilder<LlmClassificationResult?>(
          future: LlmClassifier.classify(rawMessage),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 40.0),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      TextFont(
                        text: "Querying AI Classifier...",
                        fontSize: 14,
                        textColor: getColor(context, "textLight"),
                      ),
                    ],
                  ),
                ),
              );
            }

            final res = snapshot.data;
            if (res == null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 40, color: Colors.orange),
                    const SizedBox(height: 12),
                    const TextFont(
                      text: "AI Returned No Result or Error",
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    const SizedBox(height: 6),
                    TextFont(
                      text: "Check if your Gemini API Key or Ollama endpoint is active in Review Inbox settings.",
                      fontSize: 13,
                      textColor: getColor(context, "textLight"),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.psychology_rounded,
                          color: Theme.of(context).colorScheme.primary, size: 24),
                      const SizedBox(width: 8),
                      const TextFont(
                        text: "AI Diagnostic Analysis",
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _diagRow("Is Transaction", res.isTransaction ? "YES" : "NO",
                      isHighlighted: true),
                  _diagRow("Transaction Type", res.transactionType),
                  _diagRow("Amount", "${res.currency} ${res.amount}"),
                  _diagRow("Merchant / Payee", res.merchant),
                  _diagRow("Category", res.category),
                  _diagRow("Account Hint", res.accountHint ?? "None detected"),
                  _diagRow("Confidence", "${(res.confidence * 100).toInt()}%"),
                  if (res.reasoning != null && res.reasoning!.isNotEmpty)
                    _diagRow("Reasoning", res.reasoning!),
                  const SizedBox(height: 20),
                  Button(
                    label: "Import as Review Transaction",
                    icon: Icons.add_circle_outline_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    onTap: () async {
                      Navigator.of(context).pop();
                      await ReviewManager.instance.processRawMessage(rawMessage);
                      openSnackbar(
                        SnackbarMessage(
                          title: "Imported to Review Inbox",
                          description: "Added for confirmation.",
                          icon: Icons.check_circle_outline,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _diagRow(String label, String value, {bool isHighlighted = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: TextFont(
              text: label,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              textColor: getColor(context, "textLight"),
            ),
          ),
          Expanded(
            child: TextFont(
              text: value,
              fontSize: 13,
              fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal,
              textColor: isHighlighted
                  ? Theme.of(context).colorScheme.primary
                  : getColor(context, "black"),
            ),
          ),
        ],
      ),
    );
  }

  void _runLiveScan() async {
    setState(() => _isScanning = true);
    openSnackbar(
      SnackbarMessage(
        title: "Scanning SMS Messages...",
        description: "Diagnosing incoming phone SMS inbox",
        icon: Icons.sync,
      ),
    );

    final now = DateTime.now();
    final fromDate = now.subtract(const Duration(days: 30));
    await SmsInboxScanner.scanAndImport(
      fromDate: fromDate,
      toDate: now,
      limit: 300,
    );

    if (mounted) {
      setState(() => _isScanning = false);
      openSnackbar(
        SnackbarMessage(
          title: "Scan Completed",
          description: "Inspect the diagnostic logs below to see all processed SMSes.",
          icon: Icons.check_circle_outline,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SmsDiagnosticEntry>>(
      valueListenable: SmsDiagnosticTracker.instance.logsNotifier,
      builder: (context, logs, _) {
        final filtered = logs.where((entry) {
          if (_selectedFilter != "all" && entry.status != _selectedFilter) {
            return false;
          }
          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            return entry.rawMessage.toLowerCase().contains(q) ||
                entry.sender.toLowerCase().contains(q) ||
                entry.reason.toLowerCase().contains(q) ||
                (entry.detectedMerchant?.toLowerCase().contains(q) ?? false);
          }
          return true;
        }).toList();

        final capturedCount = logs.where((e) => e.status == "captured").length;
        final otherCount = logs.where((e) => e.status == "other_sms").length;
        final skippedCount = logs.where((e) => e.status == "skipped").length;
        final dupCount = logs.where((e) => e.status == "duplicate").length;

        return PageFramework(
          title: "SMS Realtime Inspector",
          actions: [
            IconButton(
              tooltip: "Sync from Review Inbox & Accounts",
              icon: const Icon(Icons.sync_rounded),
              onPressed: () async {
                await SmsDiagnosticTracker.instance.syncHistoricalData();
                setState(() {});
                openSnackbar(
                  SnackbarMessage(
                    title: "Synced Data",
                    description:
                        "Loaded all previous Review Inbox & Account messages.",
                    icon: Icons.check_circle_outline,
                  ),
                );
              },
            ),
            IconButton(
              tooltip: "Scan Device SMS Inbox",
              icon: _isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
              onPressed: _isScanning ? null : _runLiveScan,
            ),
            if (logs.isNotEmpty)
              IconButton(
                tooltip: "Clear Logs",
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () {
                  SmsDiagnosticTracker.instance.clear();
                  setState(() {});
                },
              ),
          ],
          listWidgets: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: getColor(context, "canvasContainer"),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: getColor(context, "dividerColor").withOpacity(0.4),
                  ),
                ),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    icon: Icon(Icons.search_rounded,
                        color: getColor(context, "textLight")),
                    hintText: "Search SMS, Bank (HDFC, RBL), Payee, or Amount...",
                    hintStyle: TextStyle(
                        fontSize: 13, color: getColor(context, "textLight")),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                ),
              ),
            ),

            // Filter Chips
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip("all", "All (${logs.length})"),
                    const SizedBox(width: 6),
                    _filterChip("captured", "Captured ($capturedCount)",
                        color: Colors.green),
                    const SizedBox(width: 6),
                    _filterChip("other_sms", "Other SMS ($otherCount)",
                        color: Colors.orange),
                    const SizedBox(width: 6),
                    _filterChip("skipped", "Skipped ($skippedCount)",
                        color: Colors.red),
                    const SizedBox(width: 6),
                    _filterChip("duplicate", "Duplicates ($dupCount)",
                        color: Colors.grey),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 6),

            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60.0, horizontal: 24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.search_off_rounded,
                          size: 54,
                          color: getColor(context, "textLight").withOpacity(0.5)),
                      const SizedBox(height: 14),
                      TextFont(
                        text: logs.isEmpty
                            ? "No SMSes Inspected Yet"
                            : "No Messages Match Filter",
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      const SizedBox(height: 6),
                      TextFont(
                        text: logs.isEmpty
                            ? "Tap the scan button above or copy-paste SMSes to see real-time diagnostics on every message received."
                            : "Try clearing search keywords or switching filters.",
                        textAlign: TextAlign.center,
                        fontSize: 13,
                        textColor: getColor(context, "textLight"),
                      ),
                      if (logs.isEmpty) ...[
                        const SizedBox(height: 20),
                        Button(
                          label: "Start SMS Scan",
                          icon: Icons.history_edu_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          onTap: _runLiveScan,
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              ...filtered.map((entry) => _buildDiagnosticCard(entry)).toList(),

            const SizedBox(height: 40),
          ],
        );
      },
    );
  }

  Widget _filterChip(String filterKey, String label, {Color? color}) {
    final isSelected = _selectedFilter == filterKey;
    final primaryColor = color ?? Theme.of(context).colorScheme.primary;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _selectedFilter = filterKey),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryColor.withOpacity(0.18)
              : getColor(context, "canvasContainer"),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? primaryColor
                : getColor(context, "dividerColor").withOpacity(0.4),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: TextFont(
          text: label,
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          textColor: isSelected ? primaryColor : getColor(context, "textLight"),
        ),
      ),
    );
  }

  Widget _buildDiagnosticCard(SmsDiagnosticEntry entry) {
    Color statusColor;
    String statusTitle;
    IconData statusIcon;

    switch (entry.status) {
      case "captured":
        statusColor = Colors.green;
        statusTitle = "Captured as Transaction";
        statusIcon = Icons.check_circle_rounded;
        break;
      case "other_sms":
        statusColor = Colors.orange;
        statusTitle = "Moved to Other SMS";
        statusIcon = Icons.filter_alt_rounded;
        break;
      case "duplicate":
        statusColor = Colors.grey;
        statusTitle = "Already Logged (Duplicate)";
        statusIcon = Icons.copy_rounded;
        break;
      case "skipped":
      default:
        statusColor = Colors.red;
        statusTitle = "Skipped / Ignored";
        statusIcon = Icons.cancel_rounded;
        break;
    }

    final dateFormat = DateFormat('dd MMM, hh:mm a');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 5.0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: getColor(context, "canvasContainer"),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: getColor(context, "dividerColor").withOpacity(0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Sender Badge, Status Pill, Timestamp
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withOpacity(0.4),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: TextFont(
                    text: entry.sender,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    textColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 12, color: statusColor),
                      const SizedBox(width: 4),
                      TextFont(
                        text: statusTitle,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        textColor: statusColor,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                TextFont(
                  text: dateFormat.format(entry.timestamp),
                  fontSize: 11,
                  textColor: getColor(context, "textLight"),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Diagnostic Reason / Outcome
            TextFont(
              text: entry.reason,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              textColor: getColor(context, "black"),
            ),
            const SizedBox(height: 6),

            // Raw message text
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: getColor(context, "dividerColor").withOpacity(0.25),
                ),
              ),
              child: SelectableText(
                entry.rawMessage,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: getColor(context, "black"),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.psychology_outlined, size: 16),
                  label: const TextFont(text: "Test with AI", fontSize: 12),
                  onPressed: () => _testAiOnMessage(entry.rawMessage),
                ),
                const SizedBox(width: 6),
                Button(
                  label: "Force Import",
                  icon: Icons.add_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  textColor: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 12,
                  padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: 10, vertical: 6),
                  onTap: () async {
                    final item = await ReviewManager.instance
                        .processRawMessage(entry.rawMessage, overrideDate: entry.timestamp);
                    if (item != null) {
                      openSnackbar(
                        SnackbarMessage(
                          title: "Imported to Review Inbox",
                          description: "${item.cleanMerchant}: ₹${item.amount}",
                          icon: Icons.check_circle_outline,
                        ),
                      );
                    } else {
                      // Force manual review item creation
                      final fallbackItem = await SmsParser.createReviewTransaction(
                        entry.rawMessage,
                        overrideDate: entry.timestamp,
                      );
                      ReviewManager.instance.pendingTransactions.insert(0, fallbackItem);
                      await ReviewManager.instance.saveToStorage();
                      openSnackbar(
                        SnackbarMessage(
                          title: "Force Added to Inbox",
                          description: "Added to Review Inbox for manual review.",
                          icon: Icons.check_circle_outline,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
