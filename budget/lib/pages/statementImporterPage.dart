import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/statementImporter/statementModels.dart';
import 'package:budget/struct/statementImporter/statementParser.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

class StatementImporterPage extends StatefulWidget {
  const StatementImporterPage({Key? key}) : super(key: key);

  @override
  State<StatementImporterPage> createState() => _StatementImporterPageState();
}

class _StatementImporterPageState extends State<StatementImporterPage> {
  String? _selectedWalletPk;
  List<StatementEntry> _parsedEntries = [];
  bool _isProcessing = false;
  String? _loadedFileName;
  String _filterMode = "all"; // "all", "missing", "reconciled"

  @override
  void initState() {
    super.initState();
    _selectedWalletPk = appStateSettings["selectedWalletPk"];
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt', 'tsv', 'xlsx', 'xls', 'pdf'],
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      _loadedFileName = file.name;
      final ext = file.extension?.toLowerCase() ?? '';

      List<int>? bytes;
      if (kIsWeb) {
        bytes = file.bytes;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }

      if (bytes == null || bytes.isEmpty) return;

      setState(() => _isProcessing = true);

      List<StatementEntry> entries = [];
      if (ext == 'xlsx' || ext == 'xls') {
        entries = await StatementParser.parseExcelBytes(
          bytes,
          targetWalletPk: _selectedWalletPk,
        );
      } else if (ext == 'pdf') {
        entries = await StatementParser.parsePdfBytes(
          bytes,
          targetWalletPk: _selectedWalletPk,
        );
      } else {
        // CSV / TSV / TXT
        final content = utf8.decode(bytes, allowMalformed: true);
        entries = await StatementParser.parseCsv(
          content,
          targetWalletPk: _selectedWalletPk,
        );
      }

      setState(() {
        _parsedEntries = entries;
        _isProcessing = false;
      });

      if (entries.isEmpty) {
        openSnackbar(
          SnackbarMessage(
            title: "No Transactions Found",
            description:
                "Could not extract transactions from $ext file. Try copy-pasting statement text.",
            icon: Icons.warning_amber_rounded,
          ),
        );
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      debugPrint("Error picking file: $e");
      openSnackbar(
        SnackbarMessage(
          title: "File Parse Error",
          description: e.toString(),
          icon: Icons.error_outline,
        ),
      );
    }
  }

  Future<void> _processCsvContent(String content) async {
    setState(() => _isProcessing = true);
    try {
      final entries = await StatementParser.parseCsv(
        content,
        targetWalletPk: _selectedWalletPk,
      );

      setState(() {
        _parsedEntries = entries;
        _isProcessing = false;
      });

      if (entries.isEmpty) {
        openSnackbar(
          SnackbarMessage(
            title: "No Transactions Found",
            description:
                "Check if the content has date, narration, and amount columns.",
            icon: Icons.warning_amber_rounded,
          ),
        );
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      openSnackbar(
        SnackbarMessage(
          title: "Parse Error",
          description: e.toString(),
          icon: Icons.error_outline,
        ),
      );
    }
  }

  void _loadSampleStatement() {
    _loadedFileName = "sample_bank_statement.csv";
    const sample = """Date,Narration,Chq/Ref No,Withdrawal (Dr),Deposit (Cr),Balance
01/11/2024,SWIGGY BANGALORE UPI/430291,UPI-430291,450.00,,45200.00
01/11/2024,SALARY OCT 2024 INFOSYS,CMS-99210,,75000.00,120200.00
31/10/2024,AMAZON SELLER SERVICES MUMBAI,TXN-88123,1499.00,,44750.00
30/10/2024,HPCL PETROL PUMP BANGALORE,POS-4921,2000.00,,46249.00
29/10/2024,ATM WDL HDFC INDIRANAGAR BANGALORE,ATM-3921,5000.00,,41249.00
29/10/2024,NETFLIX MUMBAI SUBSCRIPTION,BILL-1029,649.00,,48249.00
28/10/2024,INTEREST CREDITED Q3,INT-7712,,320.00,48898.00
27/10/2024,APOLLO PHARMACY INDIRANAGAR,POS-1002,380.00,,48578.00
""";
    _processCsvContent(sample);
  }

  void _showPasteDialog() {
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
              text: "Paste Statement / CSV Content",
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            const SizedBox(height: 8),
            TextFont(
              text: "Paste raw CSV or tab-delimited text from online banking.",
              fontSize: 13,
              textColor: getColor(context, "textLight"),
            ),
            const SizedBox(height: 12),
            TextInput(
              controller: textController,
              labelText: "CSV Lines",
              bubbly: false,
              minLines: 4,
              maxLines: 8,
              padding: const EdgeInsetsDirectional.all(12),
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
                    label: "Parse Content",
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    onTap: () {
                      final txt = textController.text.trim();
                      if (txt.isEmpty) return;
                      Navigator.of(context).pop();
                      _loadedFileName = "pasted_statement.csv";
                      _processCsvContent(txt);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Opens an interactive Quick Fix / Edit Sheet for the selected row
  void _openQuickEditSheet(StatementEntry entry) async {
    final allWallets = Provider.of<AllWallets>(context, listen: false);
    final allCategories = await database.getAllCategories();
    final merchantController = TextEditingController(text: entry.cleanMerchant);
    final amountController =
        TextEditingController(text: entry.amount.toStringAsFixed(2));

    TransactionWallet? cashWallet = allWallets.list.firstWhereOrNull(
      (w) => w.name.toLowerCase().contains("cash"),
    );

    String selectedCatPk = entry.suggestedCategoryPk ??
        allCategories
            .firstWhereOrNull((c) => c.name == entry.suggestedCategoryName)
            ?.categoryPk ??
        allCategories.firstOrNull?.categoryPk ??
        "";
    String selectedCatName = allCategories
            .firstWhereOrNull((c) => c.categoryPk == selectedCatPk)
            ?.name ??
        entry.suggestedCategoryName;

    bool isIncome = entry.isIncome;
    bool isTransferToCash = entry.isTransferToCash;
    String targetWalletPk = entry.destinationWalletPk ??
        (isTransferToCash && cashWallet != null
            ? cashWallet.walletPk
            : _selectedWalletPk ?? "");

    await openBottomSheet(
      context,
      StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final isDup = entry.duplicateState != DuplicateState.unique;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text: "Fix & Reconcile Row",
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: entry.isCashWithdrawal
                              ? Colors.amber.withOpacity(0.18)
                              : isDup
                                  ? (entry.matchedSource == 'review_inbox'
                                      ? Colors.purple.withOpacity(0.15)
                                      : Colors.blue.withOpacity(0.15))
                                  : Colors.green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: TextFont(
                          text: entry.isCashWithdrawal
                              ? "Cash / ATM"
                              : isDup
                                  ? (entry.matchedSource == 'review_inbox'
                                      ? "Review Inbox"
                                      : "Reconciled")
                                  : "Missing in Cashew",
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          textColor: entry.isCashWithdrawal
                              ? Colors.amber.shade900
                              : isDup
                                  ? (entry.matchedSource == 'review_inbox'
                                      ? Colors.purple.shade900
                                      : Colors.blue.shade900)
                                  : Colors.green.shade900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Raw Statement Narration preview
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: getColor(context, "canvasContainer"),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color:
                            getColor(context, "dividerColor").withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "Original Statement Narration:",
                          fontSize: 10,
                          textColor: getColor(context, "textLight"),
                        ),
                        const SizedBox(height: 2),
                        TextFont(
                          text: entry.rawNarration,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Title / Clean Merchant
                  TextInput(
                    controller: merchantController,
                    labelText: "Transaction Name / Merchant",
                    bubbly: false,
                    padding: const EdgeInsetsDirectional.all(12),
                  ),
                  const SizedBox(height: 12),

                  // Amount & Flow Type Row
                  Row(
                    children: [
                      Expanded(
                        child: TextInput(
                          controller: amountController,
                          labelText: "Amount",
                          bubbly: false,
                          padding: const EdgeInsetsDirectional.all(12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const TextFont(text: "Expense (-)", fontSize: 11),
                        selected: !isIncome && !isTransferToCash,
                        onSelected: (_) {
                          setSheetState(() {
                            isIncome = false;
                            isTransferToCash = false;
                          });
                        },
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const TextFont(text: "Income (+)", fontSize: 11),
                        selected: isIncome && !isTransferToCash,
                        onSelected: (_) {
                          setSheetState(() {
                            isIncome = true;
                            isTransferToCash = false;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Cash Transfer Segment (User Control)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isTransferToCash
                          ? Colors.amber.withOpacity(0.12)
                          : getColor(context, "canvasContainer"),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isTransferToCash
                            ? Colors.amber.withOpacity(0.5)
                            : getColor(context, "dividerColor").withOpacity(0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.payments_rounded,
                          size: 22,
                          color: isTransferToCash
                              ? Colors.amber.shade800
                              : getColor(context, "textLight"),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFont(
                                text: "Transfer to Cash Wallet",
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                textColor: isTransferToCash
                                    ? Colors.amber.shade900
                                    : getColor(context, "black"),
                              ),
                              TextFont(
                                text:
                                    "Physical cash tracking: debits bank, credits cash wallet",
                                fontSize: 10,
                                textColor: getColor(context, "textLight"),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: isTransferToCash,
                          activeColor: Colors.amber.shade800,
                          onChanged: (val) {
                            setSheetState(() {
                              isTransferToCash = val;
                              if (val) {
                                isIncome = false;
                                if (cashWallet != null) {
                                  targetWalletPk = cashWallet.walletPk;
                                }
                              }
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Category Picker Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const TextFont(
                        text: "Category",
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.category_rounded,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 4),
                            TextFont(
                              text: selectedCatName,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              textColor: Theme.of(context).colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Quick category chips
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: allCategories.take(10).map((cat) {
                      final isSelected = cat.categoryPk == selectedCatPk;
                      return ChoiceChip(
                        label: TextFont(
                          text: cat.name,
                          fontSize: 10,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                        selected: isSelected,
                        onSelected: (_) {
                          setSheetState(() {
                            selectedCatPk = cat.categoryPk;
                            selectedCatName = cat.name;
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: Button(
                          label: "Ignore / Skip",
                          icon: Icons.cancel_outlined,
                          color: getColor(context, "canvasContainer"),
                          textColor: getColor(context, "textLight"),
                          onTap: () {
                            setState(() {
                              entry.isSelected = false;
                              entry.isUserReviewed = true;
                            });
                            Navigator.of(context).pop();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Button(
                          label: "✓ Fix & Reconcile",
                          icon: Icons.check_circle_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          onTap: () {
                            setState(() {
                              entry.cleanMerchant =
                                  merchantController.text.trim().isEmpty
                                      ? entry.cleanMerchant
                                      : merchantController.text.trim();
                              entry.amount =
                                  double.tryParse(amountController.text.trim()) ??
                                      entry.amount;
                              entry.isIncome = isIncome;
                              entry.isTransferToCash = isTransferToCash;
                              entry.suggestedCategoryPk = selectedCatPk;
                              entry.suggestedCategoryName = selectedCatName;
                              entry.destinationWalletPk = targetWalletPk;
                              entry.isUserReviewed = true;
                              entry.isSelected = true;
                            });
                            Navigator.of(context).pop();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _commitImport() async {
    final toImport = _parsedEntries.where((e) => e.isSelected).toList();
    if (toImport.isEmpty) {
      openSnackbar(
        SnackbarMessage(
          title: "None Selected",
          description: "Select at least one transaction to import.",
          icon: Icons.info_outline,
        ),
      );
      return;
    }

    final walletPk = _selectedWalletPk ?? "";
    if (walletPk.isEmpty) {
      openSnackbar(
        SnackbarMessage(
          title: "Select an Account",
          description: "Choose a target account/wallet before importing.",
          icon: Icons.account_balance_wallet_outlined,
        ),
      );
      return;
    }

    setState(() => _isProcessing = true);

    int count = 0;
    final allWallets = Provider.of<AllWallets>(context, listen: false);
    final defaultCat = (await database.getAllCategories()).firstOrNull;

    for (final entry in toImport) {
      try {
        // 1. Check if user configured this as a Transfer to Cash
        if (entry.isTransferToCash) {
          TransactionWallet? cashWallet = entry.destinationWalletPk != null
              ? allWallets.indexedByPk[entry.destinationWalletPk]
              : allWallets.list.firstWhereOrNull(
                  (w) => w.name.toLowerCase().contains("cash"),
                );

          // If no specific wallet named 'cash', fallback to another available wallet
          cashWallet ??=
              allWallets.list.firstWhereOrNull((w) => w.walletPk != walletPk);

          if (cashWallet != null) {
            final withdrawalAmt = entry.amount.abs();
            final now = entry.date;
            final note = "ATM Cash Withdrawal\nTransferred to ${cashWallet.name}\nStatement Narration: ${entry.rawNarration}" +
                (entry.referenceNo != null ? "\nRef: ${entry.referenceNo}" : "");

            final depositTxPk = uuid.v4();
            final bankTxPk = entry.id;

            // Credit Cash Wallet (Money In to Cash)
            final depositTx = Transaction(
              transactionPk: depositTxPk,
              pairedTransactionFk: bankTxPk,
              name: "Cash from ${allWallets.indexedByPk[walletPk]?.name ?? 'Bank'}",
              amount: withdrawalAmt,
              note: note,
              categoryFk: "0",
              walletFk: cashWallet.walletPk,
              dateCreated: now.add(const Duration(seconds: 1)),
              income: true,
              paid: true,
              skipPaid: false,
            );
            await database.createOrUpdateTransaction(depositTx, insert: true);

            // Debit Bank Account (Money Out from Bank)
            final bankTx = Transaction(
              transactionPk: bankTxPk,
              pairedTransactionFk: depositTxPk,
              name: entry.cleanMerchant,
              amount: -withdrawalAmt,
              note: note,
              categoryFk: "0",
              walletFk: walletPk,
              dateCreated: now,
              income: false,
              paid: true,
              skipPaid: false,
            );
            await database.createOrUpdateTransaction(bankTx, insert: true);
            count++;
            continue;
          }
        }

        // 2. Standard Transaction
        final amount =
            entry.isIncome ? entry.amount.abs() : -entry.amount.abs();
        final catPk =
            entry.suggestedCategoryPk ?? defaultCat?.categoryPk ?? "";

        final tx = Transaction(
          transactionPk: entry.id,
          name: entry.cleanMerchant,
          amount: amount,
          note: "Statement Import (${_loadedFileName ?? 'Statement'}):\n${entry.rawNarration}" +
              (entry.referenceNo != null ? "\nRef: ${entry.referenceNo}" : ""),
          categoryFk: catPk,
          walletFk: entry.destinationWalletPk ?? walletPk,
          dateCreated: entry.date,
          income: entry.isIncome,
          paid: true,
          skipPaid: false,
        );

        await database.createOrUpdateTransaction(tx, insert: true);
        count++;
      } catch (e) {
        debugPrint("Error inserting statement transaction: $e");
      }
    }

    setState(() {
      _isProcessing = false;
      _parsedEntries.clear();
      _loadedFileName = null;
    });

    openSnackbar(
      SnackbarMessage(
        title: "Import Complete!",
        description: "Successfully imported $count transactions.",
        icon: Icons.check_circle_outline,
      ),
    );

    popRoute(context);
  }

  @override
  Widget build(BuildContext context) {
    final wallets = Provider.of<AllWallets>(context).list;
    final newCount = _parsedEntries
        .where((e) =>
            e.duplicateState == DuplicateState.unique && !e.isCashWithdrawal)
        .length;
    final cashCount =
        _parsedEntries.where((e) => e.isCashWithdrawal).length;
    final dupCount = _parsedEntries
        .where((e) => e.duplicateState != DuplicateState.unique)
        .length;
    final reviewedCount =
        _parsedEntries.where((e) => e.isUserReviewed).length;
    final selectedCount = _parsedEntries.where((e) => e.isSelected).length;

    return PageFramework(
      title: "Bank Statement Importer",
      actions: [
        IconButton(
          tooltip: "Paste CSV",
          icon: const Icon(Icons.paste_rounded),
          onPressed: _showPasteDialog,
        ),
      ],
      listWidgets: [
        // Wallet / Account Selector
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
                TextFont(
                  text: "Target Account",
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  textColor: getColor(context, "textLight"),
                ),
                const SizedBox(height: 8),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedWalletPk,
                    hint: const TextFont(text: "Select Account", fontSize: 15),
                    items: wallets.map((w) {
                      return DropdownMenuItem<String>(
                        value: w.walletPk,
                        child: Row(
                          children: [
                            const Icon(Icons.account_balance_rounded, size: 20),
                            const SizedBox(width: 8),
                            TextFont(
                              text: w.name,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() => _selectedWalletPk = val);
                      if (_parsedEntries.isNotEmpty && val != null) {
                        StatementParser.checkDuplicates(_parsedEntries, val)
                            .then((_) {
                          setState(() {});
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        // File Upload / Sample Action Buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
          child: Row(
            children: [
              Expanded(
                child: Button(
                  label: "Upload Statement",
                  icon: Icons.upload_file_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  textColor: Theme.of(context).colorScheme.onPrimary,
                  onTap: _pickFile,
                ),
              ),
              const SizedBox(width: 10),
              Button(
                label: "Try Sample",
                icon: Icons.auto_awesome_rounded,
                color: getColor(context, "dividerColor").withOpacity(0.2),
                textColor: getColor(context, "black"),
                onTap: _loadSampleStatement,
              ),
            ],
          ),
        ),

        if (_isProcessing)
          const Padding(
            padding: EdgeInsets.all(32.0),
            child: Center(child: CircularProgressIndicator()),
          ),

        // Summary Bar when entries are loaded
        if (_parsedEntries.isNotEmpty) ...[
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Container(
              padding: const EdgeInsetsDirectional.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .secondaryContainer
                    .withOpacity(0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withOpacity(0.2),
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
                              text: _loadedFileName ?? "Statement",
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                            const SizedBox(height: 2),
                            TextFont(
                              text:
                                  "Reconciliation: $newCount Missing • $cashCount Cash/ATM • $dupCount Reconciled",
                              fontSize: 12,
                              textColor: getColor(context, "textLight"),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            final anyDeselected =
                                _parsedEntries.any((e) => !e.isSelected);
                            for (final e in _parsedEntries) {
                              e.isSelected = anyDeselected;
                            }
                          });
                        },
                        child: TextFont(
                          text: _parsedEntries.every((e) => e.isSelected)
                              ? "Deselect All"
                              : "Select All",
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Progress Bar of User-Reviewed Rows
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _parsedEntries.isEmpty
                          ? 0.0
                          : reviewedCount / _parsedEntries.length,
                      minHeight: 6,
                      backgroundColor:
                          getColor(context, "dividerColor").withOpacity(0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        reviewedCount == _parsedEntries.length
                            ? Colors.green
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text:
                            "Reviewed: $reviewedCount of ${_parsedEntries.length} rows (${_parsedEntries.isEmpty ? 0 : (reviewedCount / _parsedEntries.length * 100).toInt()}%)",
                        fontSize: 11,
                        textColor: getColor(context, "textLight"),
                      ),
                      InkWell(
                        onTap: () {
                          setState(() {
                            for (final e in _parsedEntries) {
                              if (e.duplicateState == DuplicateState.unique) {
                                e.isSelected = true;
                                e.isUserReviewed = true;
                              }
                            }
                          });
                        },
                        child: const TextFont(
                          text: "Mark All Missing Ready",
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          textColor: Colors.green,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Reconciliation Filter Chips
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: TextFont(
                          text: "All (${_parsedEntries.length})",
                          fontSize: 11,
                          fontWeight: _filterMode == "all"
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        selected: _filterMode == "all",
                        onSelected: (_) =>
                            setState(() => _filterMode = "all"),
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.add_circle_outline,
                            size: 14, color: Colors.green),
                        label: TextFont(
                          text: "Missing to Fix ($newCount)",
                          fontSize: 11,
                          fontWeight: _filterMode == "missing"
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        selected: _filterMode == "missing",
                        onSelected: (_) =>
                            setState(() => _filterMode = "missing"),
                      ),
                      if (cashCount > 0)
                        ChoiceChip(
                          avatar: Icon(Icons.payments_rounded,
                              size: 14, color: Colors.amber.shade800),
                          label: TextFont(
                            text: "Cash / ATM ($cashCount)",
                            fontSize: 11,
                            fontWeight: _filterMode == "cash"
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          selected: _filterMode == "cash",
                          onSelected: (_) =>
                              setState(() => _filterMode = "cash"),
                        ),
                      ChoiceChip(
                        avatar: const Icon(Icons.check_circle_outline,
                            size: 14, color: Colors.blue),
                        label: TextFont(
                          text: "Reconciled ($dupCount)",
                          fontSize: 11,
                          fontWeight: _filterMode == "reconciled"
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        selected: _filterMode == "reconciled",
                        onSelected: (_) =>
                            setState(() => _filterMode = "reconciled"),
                      ),
                    ],
                  ),

                  // Cash Callout Banner if Cash Transactions Exist
                  if (cashCount > 0) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.amber.withOpacity(0.4),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.lightbulb_outline_rounded,
                              size: 18, color: Colors.amber.shade900),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFont(
                              text:
                                  "User Control on Cash: $cashCount ATM cash withdrawal(s) detected. Tap any row to transfer funds directly into your Cash Wallet or record as cash expenses.",
                              fontSize: 11,
                              textColor: Colors.amber.shade900,
                              maxLines: 3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Entries List (Filtered by reconciliation state)
          ..._parsedEntries.where((e) {
            if (_filterMode == "missing") {
              return e.duplicateState == DuplicateState.unique &&
                  !e.isCashWithdrawal;
            } else if (_filterMode == "cash") {
              return e.isCashWithdrawal;
            } else if (_filterMode == "reconciled") {
              return e.duplicateState != DuplicateState.unique;
            }
            return true;
          }).map((entry) => _buildEntryRow(entry)),

          // Bottom Import CTA
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Button(
              label: "Import $selectedCount Transactions",
              icon: Icons.download_done_rounded,
              color: Theme.of(context).colorScheme.primary,
              textColor: Theme.of(context).colorScheme.onPrimary,
              onTap: _commitImport,
            ),
          ),
        ] else if (!_isProcessing) ...[
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 24.0, vertical: 48.0),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.receipt_long_rounded,
                    size: 64,
                    color: getColor(context, "textLight").withOpacity(0.4),
                  ),
                  const SizedBox(height: 16),
                  TextFont(
                    text: "No Statement Loaded",
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  const SizedBox(height: 8),
                  TextFont(
                    text:
                        "Upload your bank or credit card statement (.pdf, .xlsx, .xls, .csv, .txt) or tap 'Try Sample' to see AI categorization, account reconciliation, cash withdrawal tracking, and duplicate prevention in action.",
                    textAlign: TextAlign.center,
                    fontSize: 13,
                    textColor: getColor(context, "textLight"),
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildEntryRow(StatementEntry entry) {
    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[_selectedWalletPk]?.currency ??
        "";

    final isCash = entry.isCashWithdrawal;
    final isDup = entry.duplicateState != DuplicateState.unique;
    final isPendingSms = isDup && entry.matchedSource == 'review_inbox';
    final isDbMatch = isDup && entry.matchedSource == 'database';

    Color accentColor;
    Color bgTint;
    String statusTitle;
    IconData statusIcon;

    if (isCash) {
      accentColor = Colors.amber.shade800;
      bgTint = Colors.amber.withOpacity(0.06);
      statusTitle = entry.isTransferToCash
          ? "💵 Cash Withdrawal (⇄ Transfers to Cash Wallet)"
          : "💵 Cash Withdrawal (Manual Cash Control)";
      statusIcon = Icons.payments_rounded;
    } else if (isPendingSms) {
      accentColor = Colors.purple.shade700;
      bgTint = Colors.purple.withOpacity(0.05);
      statusTitle = "📨 Matches pending SMS in Review Inbox";
      statusIcon = Icons.mark_email_unread_rounded;
    } else if (isDbMatch || isDup) {
      accentColor = Colors.blue.shade700;
      bgTint = Colors.blue.withOpacity(0.05);
      statusTitle =
          entry.duplicateReason ?? "✓ Reconciled with Cashew transaction";
      statusIcon = Icons.check_circle_rounded;
    } else {
      accentColor = Colors.green.shade700;
      bgTint = Colors.green.withOpacity(0.06);
      statusTitle = "✨ Missing from Cashew (No SMS found • Ready to import)";
      statusIcon = Icons.add_circle_outline_rounded;
    }

    final amountStr =
        "${entry.isIncome ? '+' : '-'} $currency${entry.amount.toStringAsFixed(2)}";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: InkWell(
        onTap: () => _openQuickEditSheet(entry),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: bgTint,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: accentColor.withOpacity(0.4),
              width: 1.2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left accent indicator bar (5px)
                  Container(
                    width: 5,
                    color: accentColor,
                  ),
                  // Checkbox
                  Checkbox(
                    value: entry.isSelected,
                    activeColor: accentColor,
                    onChanged: (val) {
                      setState(() => entry.isSelected = val ?? false);
                    },
                  ),
                  // Main Details
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4.0, vertical: 10.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextFont(
                                  text: entry.cleanMerchant,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  maxLines: 1,
                                ),
                              ),
                              TextFont(
                                text: amountStr,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                textColor: isCash
                                    ? Colors.amber.shade900
                                    : entry.isIncome
                                        ? Colors.green
                                        : Colors.redAccent,
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              TextFont(
                                text: DateFormat('dd MMM yyyy')
                                    .format(entry.date),
                                fontSize: 12,
                                textColor: getColor(context, "textLight"),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.category_rounded,
                                      size: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                    const SizedBox(width: 4),
                                    TextFont(
                                      text: entry.suggestedCategoryName,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      textColor: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                  ],
                                ),
                              ),
                              if (entry.isUserReviewed) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const TextFont(
                                    text: "✓ Reviewed",
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    textColor: Colors.green,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 6),
                          // Status Badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(statusIcon,
                                    size: 12, color: accentColor),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: TextFont(
                                    text: statusTitle,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    textColor: accentColor,
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Edit Action Button (right)
                  IconButton(
                    icon: Icon(Icons.edit_note_rounded,
                        size: 24, color: accentColor),
                    tooltip: "Fix & Reconcile",
                    onPressed: () => _openQuickEditSheet(entry),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
