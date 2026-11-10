import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:provider/provider.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/reviewModels.dart';
import 'package:budget/struct/smsReview/smsInboxScanner.dart';
import 'package:budget/struct/smsReview/llmClassifier.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/selectCategory.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class ReviewInboxPage extends StatefulWidget {
  const ReviewInboxPage({Key? key}) : super(key: key);

  @override
  State<ReviewInboxPage> createState() => _ReviewInboxPageState();
}

class _ReviewInboxPageState extends State<ReviewInboxPage> {
  bool _isLoading = false;
  bool? _isNotificationAccessGranted;
  int _selectedTabIndex = 0; // 0: Transactions, 1: Other SMS

  @override
  void initState() {
    super.initState();
    ReviewManager.instance.init().then((_) {
      if (mounted) setState(() {});
    });
    _checkNotificationPermission();
  }

  Future<void> _checkNotificationPermission() async {
    if (getPlatform(ignoreEmulation: true) == PlatformOS.isAndroid) {
      try {
        final granted = await NotificationListenerService.isPermissionGranted();
        if (mounted) {
          setState(() {
            _isNotificationAccessGranted = granted;
          });
        }
      } catch (_) {}
    }
  }

  void _showAiModelSettingsDialog() {
    String selectedProvider =
        appStateSettings["aiProvider"]?.toString() ?? "none";
    final apiKeyController = TextEditingController(
      text: appStateSettings["geminiApiKey"]?.toString() ?? "",
    );
    final endpointController = TextEditingController(
      text: appStateSettings["ollamaEndpoint"]?.toString() ??
          "http://localhost:11434",
    );
    final modelController = TextEditingController(
      text: appStateSettings["ollamaModel"]?.toString() ?? "llama3.2",
    );

    openBottomSheet(
      context,
      StatefulBuilder(
        builder: (context, setSheetState) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.psychology_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      TextFont(
                        text: "AI Classifier Engine",
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextFont(
                    text:
                        "Choose the AI engine used to parse messy SMSes and filter out advertisements, loan offers, and balance updates.",
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                  const SizedBox(height: 16),
                  RadioListTile<String>(
                    title: const TextFont(
                      text: "Built-in Edge Rules (Fast & Offline)",
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    subtitle: const TextFont(
                      text:
                          "Strict anti-spam filters, zero setup, runs 100% offline.",
                      fontSize: 12,
                    ),
                    value: "none",
                    groupValue: selectedProvider,
                    onChanged: (val) {
                      setSheetState(() => selectedProvider = val!);
                    },
                  ),
                  RadioListTile<String>(
                    title: const TextFont(
                      text: "Google Gemini 1.5 Flash (Free Cloud API)",
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    subtitle: const TextFont(
                      text:
                          "Ultra-accurate classification & merchant parsing with 15 req/min free.",
                      fontSize: 12,
                    ),
                    value: "gemini",
                    groupValue: selectedProvider,
                    onChanged: (val) {
                      setSheetState(() => selectedProvider = val!);
                    },
                  ),
                  if (selectedProvider == "gemini") ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextInput(
                            controller: apiKeyController,
                            labelText: "Gemini API Key (AIzaSy...)",
                            bubbly: false,
                          ),
                          const SizedBox(height: 4),
                          TextFont(
                            text:
                                "Free API key from https://aistudio.google.com/ (no credit card required)",
                            fontSize: 11,
                            textColor: getColor(context, "textLight"),
                          ),
                        ],
                      ),
                    ),
                  ],
                  RadioListTile<String>(
                    title: const TextFont(
                      text: "Local Ollama (Llama 3.2 / Gemma 2 - On-Prem)",
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    subtitle: const TextFont(
                      text:
                          "Self-hosted on your PC or home server over local Wi-Fi. 100% private.",
                      fontSize: 12,
                    ),
                    value: "ollama",
                    groupValue: selectedProvider,
                    onChanged: (val) {
                      setSheetState(() => selectedProvider = val!);
                    },
                  ),
                  if (selectedProvider == "ollama") ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      child: Column(
                        children: [
                          TextInput(
                            controller: endpointController,
                            labelText: "Ollama Endpoint (e.g. http://192.168.1.100:11434)",
                            bubbly: false,
                          ),
                          const SizedBox(height: 8),
                          TextInput(
                            controller: modelController,
                            labelText: "Model Name (e.g. llama3.2 or gemma2:2b)",
                            bubbly: false,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Button(
                    label: "View & Edit AI Prompt",
                    icon: Icons.edit_note_rounded,
                    color: getColor(context, "dividerColor").withOpacity(0.18),
                    textColor: getColor(context, "black"),
                    expandedLayout: true,
                    onTap: () {
                      Navigator.of(context).pop();
                      _showEditAiPromptDialog();
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Button(
                          label: "Cancel",
                          color: getColor(context, "canvasContainer"),
                          textColor: getColor(context, "black"),
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Button(
                          label: "Save AI Settings",
                          color: Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          onTap: () async {
                            await updateSettings(
                              "aiProvider",
                              selectedProvider,
                              updateGlobalState: false,
                            );
                            await updateSettings(
                              "geminiApiKey",
                              apiKeyController.text.trim(),
                              updateGlobalState: false,
                            );
                            await updateSettings(
                              "ollamaEndpoint",
                              endpointController.text.trim(),
                              updateGlobalState: false,
                            );
                            await updateSettings(
                              "ollamaModel",
                              modelController.text.trim(),
                              updateGlobalState: false,
                            );
                            Navigator.of(context).pop();
                            setState(() {});
                            openSnackbar(
                              SnackbarMessage(
                                title: "AI Settings Saved",
                                description: selectedProvider == "gemini"
                                    ? "Active: Google Gemini 1.5 Flash (Free)"
                                    : selectedProvider == "ollama"
                                        ? "Active: Local Ollama (${modelController.text.trim()})"
                                        : "Active: Built-in Edge Rules",
                                icon: Icons.check_circle_outline,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showEditAiPromptDialog() {
    final promptController =
        TextEditingController(text: LlmClassifier.getSystemPrompt());
    openBottomSheet(
      context,
      StatefulBuilder(
        builder: (context, setDialogState) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextFont(
                      text: "AI System Prompt",
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    IconButton(
                      tooltip: "Reset to Default",
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: () {
                        setDialogState(() {
                          promptController.text =
                              LlmClassifier.defaultSystemPrompt;
                        });
                        openSnackbar(
                          SnackbarMessage(
                            title: "Reset Prompt",
                            description:
                                "Default prompt loaded. Tap Save to apply.",
                            icon: Icons.refresh_rounded,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextFont(
                  text:
                      "Verify or customize the exact prompt sent to Gemini or local Ollama. Ensure strict entity extraction and full transacted amounts.",
                  fontSize: 13,
                  maxLines: 3,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 14),
                Container(
                  height: 320,
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: getColor(context, "dividerColor"),
                    ),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    controller: promptController,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      fontFamily: "monospace",
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(context, "canvasContainer"),
                        textColor: getColor(context, "black"),
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Button(
                        label: "Save Prompt",
                        icon: Icons.save_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        textColor: Theme.of(context).colorScheme.onPrimary,
                        onTap: () async {
                          await LlmClassifier.saveSystemPrompt(
                              promptController.text);
                          Navigator.of(context).pop();
                          openSnackbar(
                            SnackbarMessage(
                              title: "Prompt Saved",
                              description:
                                  "Custom AI prompt updated and active for all parses.",
                              icon: Icons.check_circle_outline,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showPasteSmsDialog() {
    final textController = TextEditingController();
    openBottomSheet(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFont(
              text: "Paste SMS / Notification",
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            const SizedBox(height: 8),
            TextFont(
              text:
                  "Paste any bank SMS or payment notification to preview AI categorization & add it to the review inbox.",
              fontSize: 14,
              maxLines: 3,
              textColor: getColor(context, "textLight"),
            ),
            const SizedBox(height: 16),
            TextInput(
              controller: textController,
              labelText: "Message Text",
              bubbly: false,
              minLines: 3,
              maxLines: 5,
              padding: const EdgeInsetsDirectional.all(12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SampleChip(
                  label: "Swiggy UPI",
                  sample:
                      "Sent Rs.450.00 from Kotak Bank AC X1234 to SWIGGY on 02-Nov-24. UPI Ref 430291829182.",
                  onTap: (s) => textController.text = s,
                ),
                _SampleChip(
                  label: "Amazon Card",
                  sample:
                      "Alert: Rs 1,499.00 spent on your HDFC Bank Card ending 4421 at AMAZON INDIA on 01-NOV-24.",
                  onTap: (s) => textController.text = s,
                ),
                _SampleChip(
                  label: "Salary Credit",
                  sample:
                      "Your A/C ending 5678 is credited with INR 75,000.00 on 31-Oct-24 by SALARY OCT 2024. Avail Bal: Rs 82,340.",
                  onTap: (s) => textController.text = s,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Button(
                    label: "Cancel",
                    color: getColor(context, "canvasContainer"),
                    textColor: getColor(context, "black"),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Button(
                    label: "Parse with AI",
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    onTap: () async {
                      final text = textController.text.trim();
                      if (text.isEmpty) return;
                      Navigator.of(context).pop();
                      setState(() => _isLoading = true);
                      final items =
                          await ReviewManager.instance.processBatchMessages(text);
                      setState(() => _isLoading = false);
                      if (items.isNotEmpty) {
                        openSnackbar(
                          SnackbarMessage(
                            title: items.length == 1
                                ? "Transaction Captured"
                                : "${items.length} Transactions Captured",
                            description: items.length == 1
                                ? "${items.first.cleanMerchant} (${items.first.suggestedCategoryName}) on ${DateFormat('dd MMM yyyy').format(items.first.date)}"
                                : "Imported ${items.length} transactions with dates & AI categories.",
                            icon: Icons.check_circle_outline,
                          ),
                        );
                      } else {
                        openSnackbar(
                          SnackbarMessage(
                            title: "Could not parse message",
                            description:
                                "No transaction amount or debit/credit keyword detected.",
                            icon: Icons.error_outline,
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showScanPreviousSmsDialog() {
    final now = DateTime.now();
    DateTime fromDate = DateTime(now.year, now.month, 1);
    DateTime toDate = now;

    openBottomSheet(
      context,
      StatefulBuilder(
        builder: (context, setSheetState) {
          final dateFormat = DateFormat('dd MMM yyyy');
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFont(
                  text: "Scan Previous SMSes",
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                const SizedBox(height: 8),
                TextFont(
                  text:
                      "Cashew will look through your phone's SMS inbox for bank & UPI transactions (HDFC, SBI, ICICI, GPay, PhonePe, Paytm, etc.) and add them with their original transaction dates.",
                  fontSize: 14,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 16),
                TextFont(
                  text: "Date Range (Default: Start of Month to Today):",
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: fromDate,
                            firstDate: DateTime(2020),
                            lastDate: toDate,
                          );
                          if (picked != null) {
                            setSheetState(() => fromDate = picked);
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: getColor(context, "dividerColor"),
                            ),
                            borderRadius: BorderRadius.circular(12),
                            color: getColor(context, "canvasContainer"),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFont(
                                text: "From Date",
                                fontSize: 11,
                                textColor: getColor(context, "textLight"),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.calendar_today_rounded,
                                      size: 16,
                                      color:
                                          Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextFont(
                                      text: dateFormat.format(fromDate),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded,
                        size: 18, color: getColor(context, "textLight")),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: toDate,
                            firstDate: fromDate,
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setSheetState(() => toDate = picked);
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: getColor(context, "dividerColor"),
                            ),
                            borderRadius: BorderRadius.circular(12),
                            color: getColor(context, "canvasContainer"),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFont(
                                text: "To Date (Till Date)",
                                fontSize: 11,
                                textColor: getColor(context, "textLight"),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.event_available_rounded,
                                      size: 16,
                                      color:
                                          Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextFont(
                                      text: dateFormat.format(toDate),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(
                      label: const Text("This Month"),
                      onPressed: () {
                        setSheetState(() {
                          fromDate = DateTime(now.year, now.month, 1);
                          toDate = DateTime.now();
                        });
                      },
                    ),
                    ActionChip(
                      label: const Text("Last Month"),
                      onPressed: () {
                        setSheetState(() {
                          fromDate = DateTime(now.year, now.month - 1, 1);
                          toDate = DateTime(now.year, now.month, 0);
                        });
                      },
                    ),
                    ActionChip(
                      label: const Text("Past 30 Days"),
                      onPressed: () {
                        setSheetState(() {
                          fromDate = now.subtract(const Duration(days: 30));
                          toDate = DateTime.now();
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(context, "canvasContainer"),
                        textColor: getColor(context, "black"),
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Button(
                        label: "Start Scan",
                        icon: Icons.search_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        textColor: Theme.of(context).colorScheme.onPrimary,
                        onTap: () async {
                          Navigator.of(context).pop();
                          setState(() => _isLoading = true);
                          openSnackbar(
                            SnackbarMessage(
                              title: "Scanning SMS Inbox...",
                              description:
                                  "Scanning from ${dateFormat.format(fromDate)} to ${dateFormat.format(toDate)}",
                              icon: Icons.sync,
                            ),
                          );
                          final count = await SmsInboxScanner.scanAndImport(
                            fromDate: fromDate,
                            toDate: toDate,
                            limit: 1000,
                          );
                          setState(() => _isLoading = false);
                          if (count > 0) {
                            openSnackbar(
                              SnackbarMessage(
                                title: "Scan Complete",
                                description:
                                    "Found and imported $count previous transactions!",
                                icon: Icons.check_circle_outline,
                              ),
                            );
                          } else {
                            openSnackbar(
                              SnackbarMessage(
                                title: "No New Transactions",
                                description:
                                    "No new un-imported financial SMSes found in the selected period.",
                                icon: Icons.info_outline,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = ReviewManager.instance.pendingTransactions;
    final ignored = ReviewManager.instance.ignoredMessages;

    return PageFramework(
      title: "Review Inbox",
      actions: [
        IconButton(
          tooltip: "AI Model Settings (Gemini / Llama)",
          icon: const Icon(Icons.psychology_outlined),
          onPressed: _showAiModelSettingsDialog,
        ),
        if (getPlatform(ignoreEmulation: true) == PlatformOS.isAndroid)
          IconButton(
            tooltip: "Scan Previous SMSes",
            icon: const Icon(Icons.history_edu_rounded),
            onPressed: _showScanPreviousSmsDialog,
          ),
        IconButton(
          tooltip: "Paste SMS / Message",
          icon: const Icon(Icons.paste_rounded),
          onPressed: _showPasteSmsDialog,
        ),
        if (_selectedTabIndex == 0 && pending.isNotEmpty)
          IconButton(
            tooltip: "Clear All Transactions",
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              openPopup(
                context,
                title: "Clear Transactions?",
                description:
                    "This will dismiss all pending review transactions.",
                icon: Icons.delete_outline,
                onSubmitLabel: "Clear",
                onSubmit: () async {
                  Navigator.of(context).pop();
                  await ReviewManager.instance.clearAll();
                  setState(() {});
                  openSnackbar(
                    SnackbarMessage(
                      title: "Transactions Cleared",
                      description:
                          "All pending review transactions were dismissed.",
                      icon: Icons.check_circle_outline,
                    ),
                  );
                },
                onCancelLabel: "Cancel",
                onCancel: () => Navigator.of(context).pop(),
              );
            },
          )
        else if (_selectedTabIndex == 1 && ignored.isNotEmpty)
          IconButton(
            tooltip: "Clear Other SMS",
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              openPopup(
                context,
                title: "Clear Other SMS?",
                description:
                    "This will remove all non-transaction filtered SMS messages.",
                icon: Icons.delete_outline,
                onSubmitLabel: "Clear",
                onSubmit: () async {
                  Navigator.of(context).pop();
                  await ReviewManager.instance.clearAllIgnored();
                  setState(() {});
                  openSnackbar(
                    SnackbarMessage(
                      title: "Other SMS Cleared",
                      description:
                          "All non-transaction SMS messages were dismissed.",
                      icon: Icons.check_circle_outline,
                    ),
                  );
                },
                onCancelLabel: "Cancel",
                onCancel: () => Navigator.of(context).pop(),
              );
            },
          ),
      ],
      listWidgets: [
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(24.0),
            child: Center(child: CircularProgressIndicator()),
          ),

        // Android Auto-Capture Notification Access Banner
        if (getPlatform(ignoreEmulation: true) == PlatformOS.isAndroid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _isNotificationAccessGranted == true
                    ? Colors.green.withOpacity(0.08)
                    : Theme.of(context).colorScheme.primaryContainer.withOpacity(0.2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isNotificationAccessGranted == true
                      ? Colors.green.withOpacity(0.3)
                      : Theme.of(context).colorScheme.primary.withOpacity(0.25),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isNotificationAccessGranted == true
                        ? Icons.check_circle_rounded
                        : Icons.auto_awesome_rounded,
                    color: _isNotificationAccessGranted == true
                        ? Colors.green
                        : Theme.of(context).colorScheme.primary,
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: _isNotificationAccessGranted == true
                              ? "Live Auto-Capture Active"
                              : "Auto-Detect Bank SMS & UPI",
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        TextFont(
                          text: _isNotificationAccessGranted == true
                              ? "Incoming bank SMS & UPI notifications (GPay, PhonePe, Paytm) automatically flow here."
                              : "Enable Android Notification Access to automatically capture all bank SMS & payment alerts without copy-pasting.",
                          fontSize: 12,
                          maxLines: 2,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),
                  if (_isNotificationAccessGranted != true)
                    TextButton(
                      child: const Text("Enable"),
                      onPressed: () async {
                        await NotificationListenerService.requestPermission();
                        await Future.delayed(const Duration(milliseconds: 500));
                        _checkNotificationPermission();
                      },
                    ),
                ],
              ),
            ),
          ),

        // Two-Tab Switcher: Transactions vs Other SMS
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: getColor(context, "canvasContainer"),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: getColor(context, "dividerColor").withOpacity(0.5),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _selectedTabIndex = 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _selectedTabIndex == 0
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.receipt_long_rounded,
                            size: 18,
                            color: _selectedTabIndex == 0
                                ? Theme.of(context).colorScheme.onPrimary
                                : getColor(context, "textLight"),
                          ),
                          const SizedBox(width: 8),
                          TextFont(
                            text: "Transactions (${pending.length})",
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            textColor: _selectedTabIndex == 0
                                ? Theme.of(context).colorScheme.onPrimary
                                : getColor(context, "textLight"),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _selectedTabIndex = 1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _selectedTabIndex == 1
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.mark_chat_read_rounded,
                            size: 18,
                            color: _selectedTabIndex == 1
                                ? Theme.of(context).colorScheme.onPrimary
                                : getColor(context, "textLight"),
                          ),
                          const SizedBox(width: 8),
                          TextFont(
                            text: "Other SMS (${ignored.length})",
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            textColor: _selectedTabIndex == 1
                                ? Theme.of(context).colorScheme.onPrimary
                                : getColor(context, "textLight"),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // TAB 1: PENDING TRANSACTIONS
        if (_selectedTabIndex == 0) ...[
          // Summary & Fast Action Header
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
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsetsDirectional.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.mark_email_unread_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "${pending.length} Pending Review",
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        const SizedBox(height: 2),
                        TextFont(
                          text: "AI parses your SMS & categorizes spend",
                          fontSize: 13,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),
                  if (pending.isNotEmpty)
                    Button(
                      label: "Approve All",
                      icon: Icons.done_all_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      textColor: Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsetsDirectional.symmetric(
                          horizontal: 12, vertical: 8),
                      fontSize: 13,
                      onTap: () async {
                        final approvedCount =
                            await ReviewManager.instance.approveAll();
                        setState(() {});
                        openSnackbar(
                          SnackbarMessage(
                            title: "Transactions Approved",
                            description:
                                "Logged $approvedCount transactions to your accounts.",
                            icon: Icons.check_circle_outline,
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),

          // List of Pending Items
          if (pending.isEmpty)
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 60.0, horizontal: 24),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.done_all_rounded,
                      size: 64,
                      color: getColor(context, "textLight").withOpacity(0.5),
                    ),
                    const SizedBox(height: 16),
                    TextFont(
                      text: "All Caught Up!",
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    const SizedBox(height: 8),
                    TextFont(
                      text:
                          "No pending transactions in your inbox. When new SMS or payment notifications arrive, they will appear here for one-tap review.",
                      textAlign: TextAlign.center,
                      fontSize: 14,
                      textColor: getColor(context, "textLight"),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        if (getPlatform(ignoreEmulation: true) ==
                            PlatformOS.isAndroid)
                          Button(
                            label: "Scan SMS Inbox",
                            icon: Icons.history_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            textColor: Theme.of(context).colorScheme.onPrimary,
                            onTap: _showScanPreviousSmsDialog,
                          ),
                        Button(
                          label: "Paste SMS",
                          icon: Icons.paste_rounded,
                          color:
                              Theme.of(context).colorScheme.secondaryContainer,
                          textColor: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer,
                          onTap: _showPasteSmsDialog,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else
            ...pending.map((item) => _buildReviewCard(item)).toList(),
        ] else ...[
          // TAB 2: OTHER / IGNORED SMS WITH NUMBERS
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
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsetsDirectional.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .secondary
                          .withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.filter_alt_outlined,
                      color: Theme.of(context).colorScheme.secondary,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "${ignored.length} Other SMS",
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        const SizedBox(height: 2),
                        TextFont(
                          text:
                              "Non-transactions, e-mandates & alerts. Tap 'Convert & Teach AI' if missed.",
                          fontSize: 12,
                          maxLines: 2,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),
                  if (ignored.isNotEmpty)
                    Button(
                      label: "Clear All",
                      icon: Icons.delete_sweep_rounded,
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      textColor:
                          Theme.of(context).colorScheme.onSecondaryContainer,
                      padding: const EdgeInsetsDirectional.symmetric(
                          horizontal: 12, vertical: 8),
                      fontSize: 13,
                      onTap: () async {
                        await ReviewManager.instance.clearAllIgnored();
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ),

          if (ignored.isEmpty)
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 60.0, horizontal: 24),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 64,
                      color: getColor(context, "textLight").withOpacity(0.5),
                    ),
                    const SizedBox(height: 16),
                    TextFont(
                      text: "No Other SMS",
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    const SizedBox(height: 8),
                    TextFont(
                      text:
                          "Messages with numbers filtered out as future e-mandates, balance updates, or promotional notices will appear here.",
                      textAlign: TextAlign.center,
                      fontSize: 14,
                      textColor: getColor(context, "textLight"),
                    ),
                  ],
                ),
              ),
            )
          else
            ...ignored.map((item) => _buildIgnoredCard(item)).toList(),
        ],

        const SizedBox(height: 40),
      ],
    );
  }

  void _showCategoryTagPicker(ReviewTransaction item) {
    openBottomSheet(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.label_outline_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFont(
                    text: "Tag Category for ${item.cleanMerchant}",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextFont(
              text:
                  "Choose a category. You can set it to remember and tag all transactions from ${item.cleanMerchant}.",
              fontSize: 12,
              textColor: getColor(context, "textLight"),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 320,
              child: SelectCategory(
                popRoute: true,
                setSelectedCategory: (TransactionCategory? cat) {
                  if (cat == null) return;
                  _promptApplyEverywhere(item, cat);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _promptApplyEverywhere(ReviewTransaction item, TransactionCategory cat) {
    openPopup(
      context,
      title: "Tag Everywhere?",
      description:
          "Do you want to tag '${cat.name}' everywhere for all transactions from '${item.cleanMerchant}'?",
      icon: Icons.auto_awesome_rounded,
      onSubmitLabel: "Tag Everywhere",
      onSubmit: () async {
        Navigator.of(context).pop();
        await ReviewManager.instance.updateCategoryForMerchant(
          merchant: item.cleanMerchant,
          categoryName: cat.name,
          categoryPk: cat.categoryPk,
          applyEverywhere: true,
        );
        setState(() {});
        openSnackbar(
          SnackbarMessage(
            title: "Category Rule Saved",
            description:
                "Tagged '${item.cleanMerchant}' as '${cat.name}' across all transactions.",
            icon: Icons.check_circle_outline,
          ),
        );
      },
      onCancelLabel: "Only This One",
      onCancel: () async {
        Navigator.of(context).pop();
        item.suggestedCategoryName = cat.name;
        item.suggestedCategoryPk = cat.categoryPk;
        item.confidence = 1.0;
        await ReviewManager.instance.saveToStorage();
        setState(() {});
      },
    );
  }

  void _promptAccountBindingEverywhere(
      ReviewTransaction item, String? walletPk) {
    final hint = item.accountHint?.trim();
    if (hint == null || hint.isEmpty) {
      ReviewManager.instance.saveToStorage();
      setState(() {});
      return;
    }

    openPopup(
      context,
      title: "Apply Account Binding Everywhere?",
      description:
          "Do you want to bind '$hint' to this wallet for all past database transactions, other pending SMSes, and all future incoming messages?",
      icon: Icons.sync_alt_rounded,
      onSubmitLabel: "Apply to All",
      onSubmit: () async {
        Navigator.of(context).pop();
        await ReviewManager.instance.updateWalletForAccount(
          accountHint: hint,
          walletPk: walletPk,
          applyEverywhere: true,
        );
        setState(() {});
        openSnackbar(
          SnackbarMessage(
            title: "Account Bound Everywhere",
            description:
                "Mapped '$hint' to this wallet for past, present, and future transactions.",
            icon: Icons.check_circle_outline,
          ),
        );
      },
      onCancelLabel: "Only This Transaction",
      onCancel: () async {
        Navigator.of(context).pop();
        await ReviewManager.instance.updateWalletForAccount(
          accountHint: hint,
          walletPk: walletPk,
          applyEverywhere: false,
        );
        setState(() {});
      },
    );
  }

  void _showEditAccountDialog(ReviewTransaction item) async {
    final wallets = await database.getAllWallets();
    final nameController = TextEditingController(text: item.accountHint ?? "");
    String? selectedWalletPk = item.suggestedWalletPk;

    openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: "Edit Account",
        subtitle: "Choose an existing wallet or rename the account hint.",
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextInput(
                    labelText: "Account Name",
                    controller: nameController,
                    autoFocus: true,
                    icon: Icons.account_balance_rounded,
                    onChanged: (_) => setDialogState(() {}),
                    padding: const EdgeInsetsDirectional.only(bottom: 12),
                  ),
                  if (wallets.isNotEmpty) ...[
                    TextFont(
                      text: "Or Link to Existing Wallet:",
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: getColor(context, "dividerColor")),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: selectedWalletPk,
                          hint: const TextFont(
                              text: "Select a wallet...", fontSize: 13),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: TextFont(
                                  text: "None (Use Account Name)",
                                  fontSize: 13),
                            ),
                            ...wallets.map(
                              (w) => DropdownMenuItem<String?>(
                                value: w.walletPk,
                                child: TextFont(text: w.name, fontSize: 13),
                              ),
                            ),
                          ],
                          onChanged: (val) {
                            setDialogState(() {
                              selectedWalletPk = val;
                              if (val != null) {
                                final matched =
                                    wallets.firstWhere((w) => w.walletPk == val);
                                nameController.text = matched.name;
                              }
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Button(
                          label: "Cancel",
                          color: getColor(context, "canvasContainer"),
                          textColor: getColor(context, "black"),
                          onTap: () => Navigator.of(dialogContext).pop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Button(
                          label: "Save Account",
                          icon: Icons.check_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          onTap: () async {
                            final newName = nameController.text.trim();
                            if (newName.isNotEmpty) {
                              item.accountHint =
                                  ReviewManager.canonicalizeAccountName(newName);
                              item.suggestedWalletPk = selectedWalletPk;
                              Navigator.of(dialogContext).pop();
                              _promptAccountBindingEverywhere(
                                  item, selectedWalletPk);
                            }
                          },
                        ),
                      ),
                    ],
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

  Future<bool> _showAccountCreationConfirmationDialog(
      ReviewTransaction item, List<TransactionWallet> wallets) async {
    final nameController = TextEditingController(
      text: item.accountHint?.trim() ?? "Bank A/C",
    );
    String selectedCategoryPk = item.suggestedCategoryPk ?? "";
    String selectedCategoryName = item.suggestedCategoryName;
    String? chosenExistingWalletPk;
    bool confirmed = false;

    await openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: "Create New Account?",
        subtitle:
            "This account was detected from the SMS but doesn't exist yet in your wallets.",
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextInput(
                    labelText: "Account Name",
                    controller: nameController,
                    autoFocus: true,
                    icon: Icons.account_balance_rounded,
                    onChanged: (_) => setDialogState(() {}),
                    padding: const EdgeInsetsDirectional.only(bottom: 12),
                  ),
                  TextFont(
                    text: "Category:",
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () {
                      openBottomSheet(
                        context,
                        PopupFramework(
                          title: "Select Category",
                          child: SizedBox(
                            height: 320,
                            child: SelectCategory(
                              popRoute: true,
                              setSelectedCategory: (cat) {
                                if (cat != null) {
                                  setDialogState(() {
                                    selectedCategoryPk = cat.categoryPk;
                                    selectedCategoryName = cat.name;
                                  });
                                }
                              },
                            ),
                          ),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: getColor(context, "dividerColor")),
                        borderRadius: BorderRadius.circular(10),
                        color: getColor(context, "canvasContainer"),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.category_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              TextFont(
                                text: selectedCategoryName,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ],
                          ),
                          TextFont(
                            text: "Change",
                            fontSize: 12,
                            textColor: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (wallets.isNotEmpty) ...[
                    TextFont(
                      text: "Or Link to Existing Wallet Instead:",
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: getColor(context, "dividerColor")),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: chosenExistingWalletPk,
                          hint: const TextFont(
                              text: "+ Create as new account", fontSize: 13),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: TextFont(
                                  text: "+ Create as new account",
                                  fontSize: 13),
                            ),
                            ...wallets.map(
                              (w) => DropdownMenuItem<String?>(
                                value: w.walletPk,
                                child: TextFont(text: w.name, fontSize: 13),
                              ),
                            ),
                          ],
                          onChanged: (val) {
                            setDialogState(() {
                              chosenExistingWalletPk = val;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Button(
                          label: "Cancel",
                          color: getColor(context, "canvasContainer"),
                          textColor: getColor(context, "black"),
                          onTap: () => Navigator.of(dialogContext).pop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Button(
                          label: chosenExistingWalletPk != null
                              ? "Link & Log"
                              : "Confirm & Create",
                          icon: Icons.check_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          onTap: () async {
                            final finalName = nameController.text.trim();
                            if (finalName.isNotEmpty) {
                              item.accountHint =
                                  ReviewManager.canonicalizeAccountName(
                                      finalName);
                              item.suggestedCategoryPk = selectedCategoryPk;
                              item.suggestedCategoryName = selectedCategoryName;
                              item.suggestedWalletPk = chosenExistingWalletPk;
                              confirmed = true;
                              Navigator.of(dialogContext).pop();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        ),
      ),
    );

    return confirmed;
  }

  Widget _buildIgnoredCard(ReviewTransaction item) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
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
            // Top Row: Tag / Reason & Date
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.secondaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 4),
                      TextFont(
                        text: item.ignoredReason ?? "Non-Transaction Alert",
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        textColor: theme.colorScheme.onSecondaryContainer,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                TextFont(
                  text: DateFormat('dd MMM, hh:mm a').format(item.date),
                  fontSize: 12,
                  textColor: getColor(context, "textLight"),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Message text container
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor.withOpacity(0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: getColor(context, "dividerColor").withOpacity(0.3),
                ),
              ),
              child: SelectableText(
                item.rawMessage,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: getColor(context, "black"),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Action Row: "Convert & Teach AI" and "Dismiss"
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: "Dismiss",
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: getColor(context, "textLight"),
                  ),
                  onPressed: () async {
                    await ReviewManager.instance.deleteIgnored(item);
                    setState(() {});
                  },
                ),
                const SizedBox(width: 8),
                Button(
                  label: "Convert & Teach AI",
                  icon: Icons.auto_awesome_rounded,
                  color: theme.colorScheme.primary,
                  textColor: theme.colorScheme.onPrimary,
                  fontSize: 12.5,
                  padding:
                      const EdgeInsetsDirectional.symmetric(horizontal: 14, vertical: 8),
                  onTap: () async {
                    setState(() => _isLoading = true);
                    await ReviewManager.instance
                        .convertIgnoredToTransaction(item);
                    setState(() {
                      _isLoading = false;
                      _selectedTabIndex = 0; // Move to Transactions tab
                    });
                    openSnackbar(
                      SnackbarMessage(
                        title: "Converted to Transaction",
                        description:
                            "Moved to Transactions inbox & AI learned this transaction format.",
                        icon: Icons.check_circle_outline,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewCard(ReviewTransaction item) {
    final String currencySymbol;
    if (item.currency.isNotEmpty) {
      currencySymbol = item.displayCurrency;
    } else {
      currencySymbol =
          Provider.of<AllWallets>(context, listen: false).indexedByPk[
                  appStateSettings["selectedWalletPk"]]?.currency ??
              "₹";
    }

    final amountFormatted =
        "${item.isIncome ? '+' : '-'} $currencySymbol${item.amount.toStringAsFixed(2)}";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      child: Container(
        decoration: BoxDecoration(
          color: getColor(context, "canvasContainer"),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: getColor(context, "dividerColor").withOpacity(0.3),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Row: Direction Icon, Title, Amount
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: item.isIncome
                          ? Colors.green.withOpacity(0.12)
                          : Colors.red.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      item.isIncome
                          ? Icons.arrow_downward_rounded
                          : Icons.arrow_upward_rounded,
                      color: item.isIncome ? Colors.green : Colors.red,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: item.cleanMerchant,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        const SizedBox(height: 2),
                        TextFont(
                          text: getWordedDateShort(item.date),
                          fontSize: 12,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),
                  TextFont(
                    text: amountFormatted,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    textColor: item.isIncome ? Colors.green : Colors.redAccent,
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Badges Row: Category + AI Confidence + Account hint
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  InkWell(
                    onTap: () => _showCategoryTagPicker(item),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            size: 13,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          TextFont(
                            text: item.suggestedCategoryName,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            textColor: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          TextFont(
                            text:
                                "(${(item.confidence * 100).toStringAsFixed(0)}%)",
                            fontSize: 11,
                            textColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.7),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            Icons.arrow_drop_down_rounded,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (item.accountHint != null && item.accountHint!.isNotEmpty)
                    InkWell(
                      onTap: () => _showEditAccountDialog(item),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: getColor(context, "dividerColor")
                              .withOpacity(0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: getColor(context, "dividerColor")
                                .withOpacity(0.4),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextFont(
                              text: item.accountHint!,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              textColor: getColor(context, "textLight"),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.edit_rounded,
                              size: 11,
                              color: getColor(context, "textLight"),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (item.isReminder)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.18),
                        border: Border.all(
                            color: Colors.amber.shade800, width: 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: Colors.amber.shade800,
                          ),
                          const SizedBox(width: 4),
                          TextFont(
                            text: "Reminder Notice: Check if Paid",
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            textColor: Colors.amber.shade900,
                          ),
                        ],
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 10),

              // Raw snippet
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextFont(
                  text: item.rawMessage,
                  fontSize: 11,
                  maxLines: 2,
                  textColor: getColor(context, "textLight"),
                ),
              ),

              const SizedBox(height: 12),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Dismiss
                  IconButton(
                    tooltip: "Dismiss",
                    icon: Icon(
                      Icons.close_rounded,
                      color: getColor(context, "textLight"),
                    ),
                    onPressed: () async {
                      await ReviewManager.instance.dismiss(item);
                      setState(() {});
                    },
                  ),
                  const SizedBox(width: 8),

                  // Edit before saving
                  Button(
                    label: "Edit",
                    icon: Icons.edit_outlined,
                    color: getColor(context, "dividerColor").withOpacity(0.2),
                    textColor: getColor(context, "black"),
                    padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 12, vertical: 8),
                    fontSize: 13,
                    onTap: () {
                      pushRoute(
                        context,
                        AddTransactionPage(
                          routesToPopAfterDelete: RoutesToPopAfterDelete.One,
                          selectedAmount: item.amount,
                          selectedTitle: item.cleanMerchant,
                          startInitialAddTransactionSequence: false,
                          selectedDate: item.date,
                        ),
                      ).then((_) async {
                        // After manual add, dismiss from inbox
                        await ReviewManager.instance.dismiss(item);
                        setState(() {});
                      });
                    },
                  ),
                  const SizedBox(width: 8),

                  // Approve
                  Button(
                    label: "Approve",
                    icon: Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 14, vertical: 8),
                    fontSize: 13,
                    onTap: () async {
                      // 1. Check if account exists in database before creating; ask confirmation if new!
                      final wallets = await database.getAllWallets();
                      final hint = item.accountHint?.trim() ?? "";
                      final matchingWallet = hint.isNotEmpty
                          ? ReviewManager.findMatchingWallet(wallets, hint)
                          : null;

                      if (hint.isNotEmpty &&
                          matchingWallet == null &&
                          (item.suggestedWalletPk == null ||
                              item.suggestedWalletPk!.isEmpty)) {
                        final confirmed =
                            await _showAccountCreationConfirmationDialog(
                                item, wallets);
                        if (!confirmed) return;
                      } else if (item.isReminder) {
                        bool proceed = false;
                        await openPopup(
                          context,
                          title: "Verify Bill Reminder",
                          description:
                              "This message was tracked as a bill reminder for ${item.cleanMerchant} (${item.amount.toStringAsFixed(2)}).\n\nDid you actually pay this bill?",
                          icon: Icons.help_outline_rounded,
                          onSubmitLabel: "Yes, Record Paid",
                          onSubmit: () {
                            proceed = true;
                            Navigator.of(context).pop();
                          },
                          onCancelLabel: "No, Dismiss",
                          onCancel: () async {
                            Navigator.of(context).pop();
                            await ReviewManager.instance.dismiss(item);
                            setState(() {});
                          },
                        );
                        if (!proceed) return;
                      } else if (item.confidence < 0.85) {
                        bool proceed = false;
                        await openPopup(
                          context,
                          title: "Confirm Transaction",
                          description:
                              "Please confirm details before recording:\n\n• Payee: ${item.cleanMerchant}\n• Amount: $amountFormatted\n• Category: ${item.suggestedCategoryName}\n• Account: ${item.accountHint ?? 'Default Wallet'}\n\nLog this transaction?",
                          icon: Icons.help_outline_rounded,
                          onSubmitLabel: "Confirm & Log",
                          onSubmit: () {
                            proceed = true;
                            Navigator.of(context).pop();
                          },
                          onCancelLabel: "Cancel",
                          onCancel: () => Navigator.of(context).pop(),
                        );
                        if (!proceed) return;
                      }

                      final success =
                          await ReviewManager.instance.approve(item);
                      if (success) {
                        setState(() {});
                        openSnackbar(
                          SnackbarMessage(
                            title: "Logged to Accounts",
                            description:
                                "${item.cleanMerchant}: $amountFormatted",
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
      ),
    );
  }
}

class _SampleChip extends StatelessWidget {
  final String label;
  final String sample;
  final Function(String) onTap;

  const _SampleChip({
    required this.label,
    required this.sample,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: TextFont(text: label, fontSize: 12),
      backgroundColor: getColor(context, "canvasContainer"),
      onPressed: () => onTap(sample),
    );
  }
}
