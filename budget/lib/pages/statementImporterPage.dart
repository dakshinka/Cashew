import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
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
    final defaultCat = (await database.getAllCategories()).firstOrNull;

    for (final entry in toImport) {
      try {
        final amount = entry.isIncome ? entry.amount.abs() : -entry.amount.abs();
        final catPk = entry.suggestedCategoryPk ?? defaultCat?.categoryPk ?? "";

        final tx = Transaction(
          transactionPk: entry.id,
          name: entry.cleanMerchant,
          amount: amount,
          note: "Statement Import (${_loadedFileName ?? 'CSV'}):\n${entry.rawNarration}" +
              (entry.referenceNo != null ? "\nRef: ${entry.referenceNo}" : ""),
          categoryFk: catPk,
          walletFk: walletPk,
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
    final newCount = _parsedEntries.where((e) => e.duplicateState == DuplicateState.unique).length;
    final dupCount = _parsedEntries.where((e) => e.duplicateState != DuplicateState.unique).length;
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
                        StatementParser.checkDuplicates(_parsedEntries, val).then((_) {
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
              padding: const EdgeInsetsDirectional.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .secondaryContainer
                    .withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
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
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                            const SizedBox(height: 2),
                            TextFont(
                              text:
                                  "Reconciliation: $newCount Missing from Account • $dupCount Reconciled",
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
                  // Reconciliation Filter Chips
                  Wrap(
                    spacing: 6,
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
                          text: "Missing to Import ($newCount)",
                          fontSize: 11,
                          fontWeight: _filterMode == "missing"
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        selected: _filterMode == "missing",
                        onSelected: (_) =>
                            setState(() => _filterMode = "missing"),
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
                ],
              ),
            ),
          ),

          // Entries List (Filtered by reconciliation state)
          ..._parsedEntries.where((e) {
            if (_filterMode == "missing") {
              return e.duplicateState == DuplicateState.unique;
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
                        "Upload your bank or credit card statement (.pdf, .xlsx, .xls, .csv, .txt) or tap 'Try Sample' to see AI categorization, account reconciliation, and duplicate prevention in action.",
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

    final amountStr =
        "${entry.isIncome ? '+' : '-'} $currency${entry.amount.toStringAsFixed(2)}";
    final isDup = entry.duplicateState != DuplicateState.unique;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Container(
        decoration: BoxDecoration(
          color: getColor(context, "canvasContainer"),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDup
                ? Colors.blue.withOpacity(0.4)
                : Colors.green.withOpacity(0.4),
          ),
        ),
        child: CheckboxListTile(
          value: entry.isSelected,
          onChanged: (val) {
            setState(() => entry.isSelected = val ?? false);
          },
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          title: Row(
            children: [
              Expanded(
                child: TextFont(
                  text: entry.cleanMerchant,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextFont(
                text: amountStr,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                textColor: entry.isIncome ? Colors.green : Colors.redAccent,
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Row(
                children: [
                  TextFont(
                    text: DateFormat('dd MMM yyyy').format(entry.date),
                    fontSize: 12,
                    textColor: getColor(context, "textLight"),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 11,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        TextFont(
                          text: entry.suggestedCategoryName,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          textColor: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!isDup) ...[
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: TextFont(
                    text:
                        "✨ Missing from Cashew (No SMS found - Ready to import)",
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    textColor: Colors.green[800],
                  ),
                ),
              ] else if (entry.duplicateReason != null) ...[
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: TextFont(
                    text: "✓ ${entry.duplicateReason!}",
                    fontSize: 11,
                    textColor: Colors.blue[900],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
