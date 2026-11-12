import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/backupShare/backupShareManager.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/statementImporter/statementModels.dart';
import 'package:budget/struct/statementImporter/statementParser.dart';
import 'package:budget/struct/creditCard/creditCardManager.dart';
import 'package:budget/struct/categoryManagerHelper.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/navigationFramework.dart';
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
  bool _isImporting = false;
  String? _stageMessage;
  String? _loadedFileName;
  String _filterMode = "all"; // "all", "missing", "reconciled"
  DateTime? _filterStartDate;
  CreditCardStatementSummary? _creditCardSummary;

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

      setState(() {
        _isProcessing = true;
        _stageMessage = "Loading $ext statement file...";
      });

      List<int>? bytes;
      if (kIsWeb) {
        bytes = file.bytes;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }

      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _isProcessing = false;
          _stageMessage = null;
        });
        return;
      }

      if (ext == 'pdf') {
        setState(() => _stageMessage = "Verifying PDF encryption & permissions...");
        if (StatementParser.isPdfEncrypted(bytes)) {
          setState(() {
            _isProcessing = false;
            _stageMessage = null;
          });
          _promptForPdfPassword(bytes);
          return;
        }
      }

      setState(() => _stageMessage = "Extracting transaction rows & reference IDs...");

      List<StatementEntry> entries = [];
      if (ext == 'xlsx' || ext == 'xls') {
        entries = await StatementParser.parseExcelBytes(
          bytes,
          targetWalletPk: _selectedWalletPk,
        );
      } else if (ext == 'pdf') {
        try {
          entries = await StatementParser.parsePdfBytes(
            bytes,
            targetWalletPk: _selectedWalletPk,
          );
        } on PdfPasswordException catch (_) {
          setState(() {
            _isProcessing = false;
            _stageMessage = null;
          });
          _promptForPdfPassword(bytes);
          return;
        }
      } else {
        // CSV / TSV / TXT
        final content = utf8.decode(bytes, allowMalformed: true);
        entries = await StatementParser.parseCsv(
          content,
          targetWalletPk: _selectedWalletPk,
        );
      }

      // Automatic AI statement extraction directly from file bytes if deterministic parsers return 0 rows
      if (entries.isEmpty) {
        setState(() => _stageMessage = "Analyzing unformatted text with AI assistant...");
        String rawText = "";
        if (ext == 'pdf') {
          try {
            final doc = PdfDocument(inputBytes: bytes);
            rawText = PdfTextExtractor(doc).extractText();
            doc.dispose();
          } catch (_) {}
        } else {
          try {
            rawText = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {
            try {
              rawText = latin1.decode(bytes);
            } catch (_) {}
          }
        }

        if (rawText.trim().isNotEmpty) {
          entries = await StatementParser.parseStatementWithAi(
            rawText,
            targetWalletPk: _selectedWalletPk,
          );
        }
      }

      setState(() {
        _parsedEntries = entries;
        _creditCardSummary = StatementParser.lastExtractedSummary;
        _isProcessing = false;
        _stageMessage = null;
      });

      if (entries.isEmpty) {
        openSnackbar(
          SnackbarMessage(
            title: "No Transactions Detected",
            description:
                "Could not find transaction rows in the uploaded $ext file. Please verify this statement contains transaction entries.",
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
        _creditCardSummary = StatementParser.lastExtractedSummary;
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

  Future<void> _promptForPdfPassword(List<int> bytes) async {
    final passwordController = TextEditingController();
    bool obscurePassword = true;
    String? errorMessage;
    bool isDecrypting = false;

    await openBottomSheet(
      context,
      StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      color: Theme.of(sheetContext).colorScheme.primary,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFont(
                        text: "Password-Protected Statement",
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFont(
                  text:
                      "This PDF statement is encrypted. Enter the statement password to unlock (commonly Date of Birth in DDMMYYYY format, PAN number, or last digits of account/card).",
                  fontSize: 13,
                  maxLines: 4,
                  textColor: getColor(sheetContext, "textLight"),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: "Statement Password",
                    hintText: "Enter PDF password",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () {
                        setSheetState(() {
                          obscurePassword = !obscurePassword;
                        });
                      },
                    ),
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 8),
                  TextFont(
                    text: errorMessage!,
                    fontSize: 13,
                    textColor: Theme.of(sheetContext).colorScheme.error,
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Cancel",
                        color: getColor(sheetContext, "canvasContainer"),
                        textColor: getColor(sheetContext, "black"),
                        onTap: () => Navigator.of(sheetContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Button(
                        label: isDecrypting ? "Decrypting..." : "Unlock & Import",
                        color: Theme.of(sheetContext).colorScheme.primary,
                        textColor: Theme.of(sheetContext).colorScheme.onPrimary,
                        disabled: isDecrypting,
                        onTap: () async {
                          final pwd = passwordController.text.trim();
                          if (pwd.isEmpty) {
                            setSheetState(() {
                              errorMessage = "Please enter the password.";
                            });
                            return;
                          }

                          setSheetState(() {
                            isDecrypting = true;
                            errorMessage = null;
                          });

                          setState(() {
                            _isProcessing = true;
                            _stageMessage = "Decrypting statement & parsing transactions...";
                          });

                          try {
                            List<StatementEntry> entries =
                                await StatementParser.parsePdfBytes(
                              bytes,
                              targetWalletPk: _selectedWalletPk,
                              password: pwd,
                            );

                            if (entries.isEmpty) {
                              try {
                                final doc = PdfDocument(
                                    inputBytes: bytes, password: pwd);
                                final rawText =
                                    PdfTextExtractor(doc).extractText();
                                doc.dispose();
                                if (rawText.trim().isNotEmpty) {
                                  entries = await StatementParser
                                      .parseStatementWithAi(
                                    rawText,
                                    targetWalletPk: _selectedWalletPk,
                                  );
                                }
                              } catch (_) {}
                            }

                            if (!mounted) return;
                            Navigator.of(sheetContext).pop();

                            setState(() {
                              _parsedEntries = entries;
                              _creditCardSummary =
                                  StatementParser.lastExtractedSummary;
                              _isProcessing = false;
                              _stageMessage = null;
                            });

                            if (entries.isEmpty) {
                              openSnackbar(
                                SnackbarMessage(
                                  title: "No Transactions Detected",
                                  description:
                                      "Document unlocked, but no transaction entries could be detected.",
                                  icon: Icons.warning_amber_rounded,
                                ),
                              );
                            } else {
                              openSnackbar(
                                SnackbarMessage(
                                  title: "Statement Unlocked",
                                  description:
                                      "Successfully parsed ${entries.length} transactions.",
                                  icon: Icons.check_circle_outline_rounded,
                                ),
                              );
                            }
                          } on PdfPasswordException catch (pe) {
                            setSheetState(() {
                              isDecrypting = false;
                              errorMessage = pe.message;
                            });
                          } catch (e) {
                            setSheetState(() {
                              isDecrypting = false;
                              errorMessage = e.toString();
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
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

    TransactionCategory? selectedCategory = allCategories.firstWhereOrNull(
      (c) =>
          c.categoryPk == entry.suggestedCategoryPk ||
          (c.mainCategoryPk == null &&
              c.name.toLowerCase() == entry.suggestedCategoryName.toLowerCase()),
    );
    TransactionCategory? selectedSubCategory = entry.suggestedSubCategoryPk != null
        ? allCategories.firstWhereOrNull((c) => c.categoryPk == entry.suggestedSubCategoryPk)
        : null;

    String selectedCatPk = selectedCategory?.categoryPk ??
        entry.suggestedCategoryPk ??
        allCategories.firstOrNull?.categoryPk ??
        "";
    String selectedCatName = selectedCategory?.name ?? entry.suggestedCategoryName;
    String? selectedSubCatPk = selectedSubCategory?.categoryPk ?? entry.suggestedSubCategoryPk;
    String? selectedSubCatName = selectedSubCategory?.name ?? entry.suggestedSubCategoryName;

    final otherWallets =
        allWallets.list.where((w) => w.walletPk != _selectedWalletPk).toList();
    bool isIncome = entry.isIncome;
    bool isTransfer = entry.destinationWalletPk != null || entry.isTransferToCash;
    String targetWalletPk = entry.destinationWalletPk ??
        (entry.isTransferToCash && cashWallet != null
            ? cashWallet.walletPk
            : otherWallets.firstOrNull?.walletPk ?? "");

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
                        selected: !isIncome && !isTransfer,
                        onSelected: (_) {
                          setSheetState(() {
                            isIncome = false;
                            isTransfer = false;
                          });
                        },
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const TextFont(text: "Income (+)", fontSize: 11),
                        selected: isIncome && !isTransfer,
                        onSelected: (_) {
                          setSheetState(() {
                            isIncome = true;
                            isTransfer = false;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Account Transfer / Card Payment Segment (User Control)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isTransfer
                          ? Colors.blue.withOpacity(0.08)
                          : getColor(context, "canvasContainer"),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isTransfer
                            ? Colors.blue.withOpacity(0.4)
                            : getColor(context, "dividerColor").withOpacity(0.25),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.compare_arrows_rounded,
                              size: 22,
                              color: isTransfer
                                  ? Colors.blue.shade800
                                  : getColor(context, "textLight"),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextFont(
                                    text: "Transfer to Another Account",
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    textColor: isTransfer
                                        ? Colors.blue.shade900
                                        : getColor(context, "black"),
                                  ),
                                  TextFont(
                                    text:
                                        "Credit Card bill payment, cash withdrawal, or inter-account transfer",
                                    fontSize: 10,
                                    textColor: getColor(context, "textLight"),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: isTransfer,
                              activeColor: Colors.blue.shade800,
                              onChanged: (val) {
                                setSheetState(() {
                                  isTransfer = val;
                                  if (val) {
                                    isIncome = false;
                                    if (targetWalletPk.isEmpty || targetWalletPk == _selectedWalletPk) {
                                      targetWalletPk = otherWallets.firstOrNull?.walletPk ?? "";
                                    }
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                        if (isTransfer && otherWallets.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const TextFont(
                            text: "Destination Account:",
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final w in otherWallets)
                                ChoiceChip(
                                  label: TextFont(
                                    text: w.name,
                                    fontSize: 11,
                                    fontWeight: targetWalletPk == w.walletPk
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  selected: targetWalletPk == w.walletPk,
                                  onSelected: (selected) {
                                    if (selected) {
                                      setSheetState(() {
                                        targetWalletPk = w.walletPk;
                                      });
                                    }
                                  },
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Category & Subcategory Picker Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const TextFont(
                        text: "Category & Subcategory",
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      InkWell(
                        onTap: () async {
                          final mainAndSub = await selectCategorySequence(
                            sheetContext,
                            selectedCategory: selectedCategory,
                            setSelectedCategory: (cat) {
                              selectedCategory = cat;
                            },
                            selectedSubCategory: selectedSubCategory,
                            setSelectedSubCategory: (sub) {
                              selectedSubCategory = sub;
                            },
                            selectedIncomeInitial: isIncome,
                          );
                          setSheetState(() {
                            if (mainAndSub.main != null) {
                              selectedCategory = mainAndSub.main;
                              selectedSubCategory = mainAndSub.sub;
                              selectedCatPk = mainAndSub.main!.categoryPk;
                              selectedCatName = mainAndSub.main!.name;
                              selectedSubCatPk = mainAndSub.sub?.categoryPk;
                              selectedSubCatName = mainAndSub.sub?.name;
                            }
                          });
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
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
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.category_rounded,
                                  size: 14,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 6),
                              TextFont(
                                text: selectedSubCatName != null &&
                                        selectedSubCatName!.isNotEmpty
                                    ? "$selectedCatName • $selectedSubCatName"
                                    : selectedCatName,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                textColor: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.edit_outlined,
                                  size: 12,
                                  color: Theme.of(context).colorScheme.primary),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Recommended fee types for credit card and bank charges
                  if (CategoryManagerHelper.isFinancialOrCardCharge(entry.rawNarration)) ...[
                    const TextFont(
                      text: "Recommended Fee Type:",
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        CategoryManagerHelper.subCatInterest,
                        CategoryManagerHelper.subCatEmi,
                        CategoryManagerHelper.subCatTaxes,
                        CategoryManagerHelper.subCatBankCharges,
                      ].map((subName) {
                        final isSel = selectedSubCatName == subName;
                        return ChoiceChip(
                          label: TextFont(
                            text: subName,
                            fontSize: 10,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          ),
                          selected: isSel,
                          onSelected: (_) async {
                            final ensured = await CategoryManagerHelper.ensureFinancialCategoriesExist(
                              context,
                              askConfirmation: false,
                            );
                            if (ensured != null) {
                              setSheetState(() {
                                selectedCatPk = ensured['main']!.categoryPk;
                                selectedCatName = ensured['main']!.name;
                                selectedCategory = ensured['main'];
                                TransactionCategory? targetSub;
                                if (subName == CategoryManagerHelper.subCatInterest) {
                                  targetSub = ensured['interest'];
                                } else if (subName == CategoryManagerHelper.subCatEmi) {
                                  targetSub = ensured['emi'];
                                } else if (subName == CategoryManagerHelper.subCatTaxes) {
                                  targetSub = ensured['taxes'];
                                } else {
                                  targetSub = ensured['charges'];
                                }
                                selectedSubCategory = targetSub;
                                selectedSubCatPk = targetSub?.categoryPk;
                                selectedSubCatName = targetSub?.name;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Quick category chips
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: allCategories
                        .where((c) => c.mainCategoryPk == null)
                        .take(8)
                        .map((cat) {
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
                            selectedCategory = cat;
                            selectedCatPk = cat.categoryPk;
                            selectedCatName = cat.name;
                            selectedSubCategory = null;
                            selectedSubCatPk = null;
                            selectedSubCatName = null;
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
                          onTap: () async {
                            final newMerchant =
                                merchantController.text.trim().isEmpty
                                    ? entry.cleanMerchant
                                    : merchantController.text.trim();
                            final newAmt =
                                double.tryParse(amountController.text.trim()) ??
                                    entry.amount;

                            final origCatPk = entry.suggestedCategoryPk ?? "";
                            final origSubCatPk = entry.suggestedSubCategoryPk;
                            final bool catChanged = (selectedCatPk != origCatPk ||
                                selectedSubCatPk != origSubCatPk);

                            if (catChanged && !isTransfer) {
                              Navigator.of(context).pop();
                              final applyEverywhere =
                                  await CategoryManagerHelper.propagateCategoryChange(
                                context,
                                merchantTitle: newMerchant,
                                newCategoryPk: selectedCatPk,
                                newSubCategoryPk: selectedSubCatPk,
                                newCategoryName: selectedCatName,
                                newSubCategoryName: selectedSubCatName,
                              );

                              if (applyEverywhere) {
                                final cleanTarget = newMerchant.toLowerCase().trim();
                                for (final item in _parsedEntries) {
                                  final itemClean = item.cleanMerchant.toLowerCase().trim();
                                  if (itemClean == cleanTarget ||
                                      itemClean.contains(cleanTarget) ||
                                      cleanTarget.contains(itemClean)) {
                                    item.suggestedCategoryPk = selectedCatPk;
                                    item.suggestedCategoryName = selectedCatName;
                                    item.suggestedSubCategoryPk = selectedSubCatPk;
                                    item.suggestedSubCategoryName = selectedSubCatName;
                                    item.isUserReviewed = true;
                                  }
                                }
                              }

                              setState(() {
                                entry.cleanMerchant = newMerchant;
                                entry.amount = newAmt;
                                entry.isIncome = isIncome;
                                entry.destinationWalletPk = null;
                                entry.isTransferToCash = false;
                                entry.suggestedCategoryPk = selectedCatPk;
                                entry.suggestedCategoryName = selectedCatName;
                                entry.suggestedSubCategoryPk = selectedSubCatPk;
                                entry.suggestedSubCategoryName = selectedSubCatName;
                                entry.isUserReviewed = true;
                                entry.isSelected = true;
                              });
                              return;
                            }

                            setState(() {
                              entry.cleanMerchant = newMerchant;
                              entry.amount = newAmt;
                              entry.isIncome = isIncome;
                              entry.destinationWalletPk =
                                  isTransfer ? targetWalletPk : null;
                              entry.isTransferToCash = isTransfer &&
                                  (allWallets.indexedByPk[targetWalletPk]
                                          ?.name
                                          .toLowerCase()
                                          .contains("cash") ??
                                      false);
                              entry.suggestedCategoryPk =
                                  isTransfer ? "0" : selectedCatPk;
                              entry.suggestedCategoryName =
                                  isTransfer ? "Transfer" : selectedCatName;
                              entry.suggestedSubCategoryPk =
                                  isTransfer ? null : selectedSubCatPk;
                              entry.suggestedSubCategoryName =
                                  isTransfer ? null : selectedSubCatName;
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
    if (_isImporting || _isProcessing) return;
    _isImporting = true;
    setState(() {
      _isProcessing = true;
      _stageMessage = "Deduplicating & importing selected transactions...";
    });

    try {
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

      // Assign deterministic IDs based on target wallet and row details
      StatementParser.assignDeterministicIds(_parsedEntries,
          walletPk: walletPk);

      final allWallets = Provider.of<AllWallets>(context, listen: false);
      final allCategories = await database.getAllCategories();
      final defaultCat = allCategories.firstOrNull;

      // 1. Fetch existing transactions to guarantee pre-insertion deduplication
      final existingTxns =
          await database.getAllTransactionsFromWallet(walletPk);

      final List<StatementEntry> verifiedToImport = [];
      int alreadyInDbCount = 0;

      for (final entry in toImport) {
        final entryDateOnly =
            DateTime(entry.date.year, entry.date.month, entry.date.day);
        final alreadyExists = existingTxns.any((t) {
          if (t.transactionPk == entry.id) return true;

          final tDateOnly = DateTime(
              t.dateCreated.year, t.dateCreated.month, t.dateCreated.day);
          final diffDays = tDateOnly.difference(entryDateOnly).inDays.abs();
          if (diffDays > 2) return false;

          final amountMatches =
              (t.amount.abs() - entry.amount.abs()).abs() < 0.01;
          if (!amountMatches) return false;

          final typeMatches = (t.income == entry.isIncome);
          if (!typeMatches) return false;

          final noteMatches = (entry.referenceNo != null &&
                  entry.referenceNo!.isNotEmpty &&
                  t.note.contains(entry.referenceNo!)) ||
              t.note.contains(entry.rawNarration.trim()) ||
              t.name.toLowerCase() == entry.cleanMerchant.toLowerCase();

          return noteMatches ||
              (diffDays == 0 &&
                  t.name
                      .toLowerCase()
                      .contains(entry.cleanMerchant.toLowerCase().split(' ').first));
        });

        if (alreadyExists) {
          alreadyInDbCount++;
        } else {
          verifiedToImport.add(entry);
        }
      }

      if (verifiedToImport.isEmpty) {
        openSnackbar(
          SnackbarMessage(
            title: "Already Imported",
            description:
                "All $alreadyInDbCount selected transactions already exist in this account. No duplicates were added.",
            icon: Icons.info_outline,
          ),
        );
        return;
      }

      // Check if financial charges exist (interest, EMI, taxes, fees)
      final hasFinancial = verifiedToImport.any((e) =>
          e.isCreditCardInterest ||
          e.isCreditCardGst ||
          e.isCreditCardEmi ||
          CategoryManagerHelper.isFinancialOrCardCharge(e.rawNarration));

      Map<String, TransactionCategory>? financialCategories;
      if (hasFinancial) {
        financialCategories = await CategoryManagerHelper.ensureFinancialCategoriesExist(
          context,
          askConfirmation: true,
        );
      }

      int count = 0;

      for (final entry in verifiedToImport) {
        try {
          // 1. Check if user configured this as a Transfer (to Credit Card, Cash, etc.)
          final isTransfer =
              entry.destinationWalletPk != null || entry.isTransferToCash;
          if (isTransfer) {
            TransactionWallet? targetWallet = entry.destinationWalletPk != null
                ? allWallets.indexedByPk[entry.destinationWalletPk]
                : allWallets.list.firstWhereOrNull(
                    (w) => w.name.toLowerCase().contains("cash"),
                  );

            // If no specific wallet found, fallback to another available wallet
            targetWallet ??=
                allWallets.list.firstWhereOrNull((w) => w.walletPk != walletPk);

            if (targetWallet != null) {
              final withdrawalAmt = entry.amount.abs();
              final now = entry.date;
              final isCash =
                  targetWallet.name.toLowerCase().contains("cash");
              final isCard =
                  targetWallet.name.toLowerCase().contains("card") ||
                      targetWallet.name.toLowerCase().contains("credit");

              final note = (isCash
                      ? "ATM Cash Withdrawal\n"
                      : isCard
                          ? "Credit Card Bill Payment\n"
                          : "Account Transfer\n") +
                  "Transferred to ${targetWallet.name}\nStatement Narration: ${entry.rawNarration}" +
                  (entry.referenceNo != null
                      ? "\nRef: ${entry.referenceNo}"
                      : "");

              final depositTxPk = "${entry.id}_transfer";
              final bankTxPk = entry.id;

              // Credit Target Wallet (e.g. Credit Card or Cash)
              final depositTx = Transaction(
                transactionPk: depositTxPk,
                pairedTransactionFk: bankTxPk,
                name: isCash
                    ? "Cash from ${allWallets.indexedByPk[walletPk]?.name ?? 'Bank'}"
                    : "Payment from ${allWallets.indexedByPk[walletPk]?.name ?? 'Bank'}",
                amount: withdrawalAmt,
                note: note,
                categoryFk: "0",
                walletFk: targetWallet.walletPk,
                dateCreated: now.add(const Duration(seconds: 1)),
                income: true,
                paid: true,
                skipPaid: false,
              );
              await database.createOrUpdateTransaction(depositTx,
                  insert: false);

              // Debit Bank Account (Money Out from Bank)
              final bankTx = Transaction(
                transactionPk: bankTxPk,
                pairedTransactionFk: depositTxPk,
                name: isCard
                    ? "Pay ${targetWallet.name}"
                    : entry.cleanMerchant,
                amount: -withdrawalAmt,
                note: note,
                categoryFk: "0",
                walletFk: walletPk,
                dateCreated: now,
                income: false,
                paid: true,
                skipPaid: false,
              );
              await database.createOrUpdateTransaction(bankTx, insert: false);
              count++;
              continue;
            }
          }

          // 2. Standard Transaction
          final amount =
              entry.isIncome ? entry.amount.abs() : -entry.amount.abs();

          String catPk = entry.suggestedCategoryPk ?? "";
          String? subCatPk = entry.suggestedSubCategoryPk;

          // If financial category was created/ensured and this is a bank/card charge
          if (financialCategories != null &&
              (catPk.isEmpty || catPk == defaultCat?.categoryPk) &&
              (entry.isCreditCardInterest ||
                  entry.isCreditCardGst ||
                  entry.isCreditCardEmi ||
                  CategoryManagerHelper.isFinancialOrCardCharge(entry.rawNarration))) {
            catPk = financialCategories['main']!.categoryPk;
            final subName = CategoryManagerHelper.getRecommendedSubCategoryName(entry.rawNarration);
            if (subName == CategoryManagerHelper.subCatInterest) {
              subCatPk = financialCategories['interest']?.categoryPk;
            } else if (subName == CategoryManagerHelper.subCatEmi) {
              subCatPk = financialCategories['emi']?.categoryPk;
            } else if (subName == CategoryManagerHelper.subCatTaxes) {
              subCatPk = financialCategories['taxes']?.categoryPk;
            } else {
              subCatPk = financialCategories['charges']?.categoryPk;
            }
          }

          if (catPk.isEmpty) {
            final found = allCategories.firstWhereOrNull(
              (c) => c.name.toLowerCase() == entry.suggestedCategoryName.toLowerCase(),
            );
            catPk = found?.categoryPk ?? defaultCat?.categoryPk ?? "";
          }

          final refId = StatementParser.extractReferenceId(entry.rawNarration,
              explicitRef: entry.referenceNo);
          final method =
              StatementParser.extractPaymentMethod(entry.rawNarration);

          final note =
              "[Source: Bank Statement (${_loadedFileName ?? 'Statement'})]\n" +
                  (refId != null ? "Ref ID: $refId\n" : "") +
                  "Method: $method\n" +
                  "Narration: ${entry.rawNarration}";

          final tx = Transaction(
            transactionPk: entry.id,
            name: entry.cleanMerchant,
            amount: amount,
            note: note,
            categoryFk: catPk,
            subCategoryFk: subCatPk,
            walletFk: entry.destinationWalletPk ?? walletPk,
            dateCreated: entry.date,
            income: entry.isIncome,
            paid: true,
            skipPaid: false,
          );

          await database.createOrUpdateTransaction(tx, insert: false);
          count++;
        } catch (e) {
          debugPrint("Error inserting statement transaction: $e");
        }
      }

      // Automatically synchronize statement baseline, credit limit & cycle to card config
      if (_creditCardSummary != null && _creditCardSummary!.hasData) {
        final currentConfig = CreditCardManager.instance.getConfig(walletPk);
        int? graceDays;
        if (_creditCardSummary!.statementDate != null &&
            _creditCardSummary!.dueDate != null) {
          final diff = _creditCardSummary!.dueDate!
              .difference(_creditCardSummary!.statementDate!)
              .inDays;
          if (diff >= 5 && diff <= 45) {
            graceDays = diff;
          }
        }
        final updatedConfig = currentConfig.copyWith(
          isEnabled: true,
          creditLimit: (_creditCardSummary!.creditLimit != null &&
                  _creditCardSummary!.creditLimit! > 0)
              ? _creditCardSummary!.creditLimit!
              : currentConfig.creditLimit,
          billingCycleDay: _creditCardSummary!.statementDate != null
              ? _creditCardSummary!.statementDate!.day
              : currentConfig.billingCycleDay,
          gracePeriodDays: graceDays ?? currentConfig.gracePeriodDays,
          lastStatementBalance: _creditCardSummary!.totalAmountDue ??
              currentConfig.lastStatementBalance,
          lastStatementMinDue: _creditCardSummary!.minAmountDue ??
              currentConfig.lastStatementMinDue,
          lastStatementDate: _creditCardSummary!.statementDate ??
              currentConfig.lastStatementDate,
          lastPaymentDueDate: _creditCardSummary!.dueDate ??
              currentConfig.lastPaymentDueDate,
          lastStatementFinanceCharges: _creditCardSummary!.financeCharges ??
              currentConfig.lastStatementFinanceCharges,
          lastStatementGst: _creditCardSummary!.gstCharges ??
              currentConfig.lastStatementGst,
          previousStatementDue: _creditCardSummary!.previousStatementDue ??
              currentConfig.previousStatementDue,
          lastStatementPayments: _creditCardSummary!.paymentsReceived ??
              currentConfig.lastStatementPayments,
          lastStatementPurchases: _creditCardSummary!.purchasesCurrentCycle ??
              currentConfig.lastStatementPurchases,
          availableCreditLimit: _creditCardSummary!.availableCreditLimit ??
              currentConfig.availableCreditLimit,
          availableCashLimit: _creditCardSummary!.availableCashLimit ??
              currentConfig.availableCashLimit,
          cardLast4: _creditCardSummary!.cardLast4 ?? currentConfig.cardLast4,
          billingPeriod:
              _creditCardSummary!.billingPeriod ?? currentConfig.billingPeriod,
        );
        await CreditCardManager.instance.saveConfig(updatedConfig);
      }

      setState(() {
        _parsedEntries.clear();
        _loadedFileName = null;
      });

      final skipMsg = alreadyInDbCount > 0
          ? " (prevented $alreadyInDbCount duplicates)"
          : "";
      openSnackbar(
        SnackbarMessage(
          title: "Import Complete!",
          description: "Successfully imported $count transactions$skipMsg.",
          icon: Icons.check_circle_outline,
        ),
      );

      // Refresh home and navigation state
      homePageStateKey.currentState?.refreshState();
      popRoute(context);
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _isImporting = false;
          _stageMessage = null;
        });
      }
    }
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
          onPressed: _isProcessing ? null : _showPasteDialog,
        ),
        IconButton(
          tooltip: "Clean Duplicates",
          icon: const Icon(Icons.find_replace_rounded),
          onPressed: _isProcessing
              ? null
              : () async {
                  final wallet = wallets.firstWhereOrNull(
                      (w) => w.walletPk == _selectedWalletPk);
                  await BackupShareManager
                      .findAndRemoveDuplicatesWithConfirmation(
                    context,
                    targetWalletPk: _selectedWalletPk,
                    targetWalletName: wallet?.name,
                  );
                  if (mounted &&
                      _parsedEntries.isNotEmpty &&
                      _selectedWalletPk != null) {
                    await StatementParser.checkDuplicates(
                        _parsedEntries, _selectedWalletPk!);
                    setState(() {});
                  }
                },
        ),
        IconButton(
          tooltip: "Purge Transactions",
          icon: const Icon(Icons.delete_sweep_rounded),
          onPressed: _isProcessing
              ? null
              : () async {
                  final wallet = wallets.firstWhereOrNull(
                      (w) => w.walletPk == _selectedWalletPk);
                  await BackupShareManager
                      .purgeOnlyTransactionsWithConfirmation(
                    context,
                    targetWalletPk: _selectedWalletPk,
                    targetWalletName: wallet?.name,
                  );
                  if (mounted &&
                      _parsedEntries.isNotEmpty &&
                      _selectedWalletPk != null) {
                    await StatementParser.checkDuplicates(
                        _parsedEntries, _selectedWalletPk!);
                    setState(() {});
                  }
                },
        ),
        if (_parsedEntries.isNotEmpty)
          IconButton(
            tooltip: _isProcessing
                ? "Importing..."
                : "Import $selectedCount Selected",
            icon: _isProcessing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.download_done_rounded),
                      if (selectedCount > 0)
                        Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            constraints: const BoxConstraints(
                                minWidth: 14, minHeight: 14),
                            child: Center(
                              child: Text(
                                selectedCount > 99 ? "99+" : "$selectedCount",
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
            onPressed: (_isProcessing || selectedCount == 0)
                ? null
                : _commitImport,
          ),
      ],
      floatingActionButton: _parsedEntries.isNotEmpty
          ? Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withOpacity(0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: FloatingActionButton.extended(
                backgroundColor: (_isProcessing || selectedCount == 0)
                    ? Theme.of(context).colorScheme.primary.withOpacity(0.5)
                    : Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                elevation: 4,
                icon: _isProcessing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download_done_rounded),
                label: TextFont(
                  text: _isProcessing
                      ? "Importing..."
                      : selectedCount > 0
                          ? "Import ($selectedCount)"
                          : "Import (0)",
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  textColor: Theme.of(context).colorScheme.onPrimary,
                ),
                onPressed: (_isProcessing || selectedCount == 0)
                    ? null
                    : _commitImport,
              ),
            )
          : null,
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
                flex: 3,
                child: Button(
                  label: "Upload Statement",
                  icon: Icons.upload_file_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  textColor: Theme.of(context).colorScheme.onPrimary,
                  onTap: _pickFile,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Button(
                  label: "Try Sample",
                  icon: Icons.auto_awesome_rounded,
                  color: getColor(context, "dividerColor").withOpacity(0.2),
                  textColor: getColor(context, "black"),
                  onTap: _loadSampleStatement,
                ),
              ),
            ],
          ),
        ),

        if (_isProcessing)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withOpacity(0.35),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withOpacity(0.3),
                ),
              ),
              child: Column(
                children: [
                  const CircularProgressIndicator(strokeWidth: 3),
                  const SizedBox(height: 16),
                  TextFont(
                    text: _stageMessage ?? "Processing Statement...",
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  TextFont(
                    text:
                        "Analyzing document tables, extracting reference IDs, and reconciling duplicates...",
                    fontSize: 12,
                    textColor: getColor(context, "textLight"),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                          const SizedBox(width: 6),
                          Button(
                            label: _isProcessing
                                ? "Importing..."
                                : "Import ($selectedCount)",
                            icon: Icons.download_done_rounded,
                            fontSize: 12,
                            disabled: _isProcessing || selectedCount == 0,
                            padding: const EdgeInsetsDirectional.symmetric(
                                horizontal: 10, vertical: 8),
                            color: Theme.of(context).colorScheme.primary,
                            textColor:
                                Theme.of(context).colorScheme.onPrimary,
                            onTap: _commitImport,
                          ),
                        ],
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
                      ActionChip(
                        avatar: Icon(Icons.calendar_today_rounded,
                            size: 13,
                            color: _filterStartDate != null
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey),
                        label: TextFont(
                          text: _filterStartDate == null
                              ? "Filter Date (e.g. From 30 Oct)"
                              : "From ${DateFormat('dd MMM yyyy').format(_filterStartDate!)}",
                          fontSize: 11,
                          fontWeight: _filterStartDate != null
                              ? FontWeight.bold
                              : FontWeight.normal,
                          textColor: _filterStartDate != null
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _filterStartDate ?? DateTime(2026, 10, 30),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setState(() {
                              _filterStartDate = picked;
                              for (final e in _parsedEntries) {
                                if (e.date.isBefore(picked)) {
                                  e.isSelected = false;
                                } else if (e.duplicateState == DuplicateState.unique) {
                                  e.isSelected = true;
                                }
                              }
                            });
                          }
                        },
                      ),
                      if (_filterStartDate != null)
                        ActionChip(
                          avatar: const Icon(Icons.close_rounded, size: 13),
                          label: const TextFont(
                            text: "Clear Date",
                            fontSize: 11,
                          ),
                          onPressed: () {
                            setState(() {
                              _filterStartDate = null;
                              for (final e in _parsedEntries) {
                                if (e.duplicateState == DuplicateState.unique) {
                                  e.isSelected = true;
                                }
                              }
                            });
                          },
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

          _buildCreditCardSummaryCard(),

          // Entries List (Filtered by reconciliation state & optional start date)
          ..._parsedEntries.where((e) {
            if (_filterStartDate != null && e.date.isBefore(_filterStartDate!)) {
              return false;
            }
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
              label: _isProcessing
                  ? "Importing..."
                  : "Import $selectedCount Transactions",
              icon: Icons.download_done_rounded,
              disabled: _isProcessing || selectedCount == 0,
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

  Widget _buildCreditCardSummaryCard() {
    if (_creditCardSummary == null || !_creditCardSummary!.hasData) {
      return const SizedBox.shrink();
    }

    final s = _creditCardSummary!;
    final allWallets = Provider.of<AllWallets>(context, listen: false);
    final wallet = allWallets.indexedByPk[_selectedWalletPk];
    final currency = wallet?.currency ?? "₹";

    final totalDueStr = s.totalAmountDue != null
        ? "$currency${s.totalAmountDue!.toStringAsFixed(2)}"
        : null;
    final minDueStr = s.minAmountDue != null
        ? "$currency${s.minAmountDue!.toStringAsFixed(2)}"
        : null;
    final financeChargesStr = s.financeCharges != null
        ? "$currency${s.financeCharges!.toStringAsFixed(2)}"
        : null;
    final gstStr = s.gstCharges != null
        ? "$currency${s.gstCharges!.toStringAsFixed(2)}"
        : null;

    final dateFormat = DateFormat('dd MMM yyyy');

    int? gracePeriodDays;
    if (s.statementDate != null && s.dueDate != null) {
      gracePeriodDays = s.dueDate!.difference(s.statementDate!).inDays;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.credit_score_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextFont(
                              text: s.cardName != null
                                  ? "${s.cardName}${s.cardLast4 != null ? ' (•••• ${s.cardLast4})' : ''}"
                                  : "Credit Card Billing Statement Details",
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              textColor: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: TextFont(
                              text: s.extractedVia?.startsWith("template:") ==
                                      true
                                  ? "⚡ Programmatic Template (${s.extractedVia!.replaceFirst('template:', '')})"
                                  : (s.extractedVia?.startsWith("llm:") == true
                                      ? "🧠 AI Learned Template"
                                      : "Extracted from official statement"),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              textColor:
                                  Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (wallet != null)
                  Button(
                    label: "Sync Card",
                    icon: Icons.sync_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    textColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 10, vertical: 6),
                    fontSize: 12,
                    onTap: () async {
                      final config =
                          CreditCardManager.instance.getConfig(wallet.walletPk);
                      if (s.statementDate != null) {
                        config.billingCycleDay = s.statementDate!.day;
                        config.lastStatementDate = s.statementDate;
                      }
                      if (s.dueDate != null) {
                        config.lastPaymentDueDate = s.dueDate;
                      }
                      if (gracePeriodDays != null &&
                          gracePeriodDays >= 5 &&
                          gracePeriodDays <= 45) {
                        config.gracePeriodDays = gracePeriodDays;
                      }
                      if (s.creditLimit != null && s.creditLimit! > 0) {
                        config.creditLimit = s.creditLimit!;
                      }
                      if (s.totalAmountDue != null) {
                        config.lastStatementBalance = s.totalAmountDue!;
                      }
                      if (s.minAmountDue != null) {
                        config.lastStatementMinDue = s.minAmountDue!;
                      }
                      if (s.financeCharges != null) {
                        config.lastStatementFinanceCharges = s.financeCharges!;
                      }
                      if (s.gstCharges != null) {
                        config.lastStatementGst = s.gstCharges!;
                      }
                      if (s.previousStatementDue != null) {
                        config.previousStatementDue = s.previousStatementDue!;
                      }
                      if (s.paymentsReceived != null) {
                        config.lastStatementPayments = s.paymentsReceived!;
                      }
                      if (s.purchasesCurrentCycle != null) {
                        config.lastStatementPurchases =
                            s.purchasesCurrentCycle!;
                      }
                      if (s.availableCreditLimit != null) {
                        config.availableCreditLimit = s.availableCreditLimit;
                      }
                      if (s.availableCashLimit != null) {
                        config.availableCashLimit = s.availableCashLimit;
                      }
                      if (s.cardLast4 != null) {
                        config.cardLast4 = s.cardLast4;
                      }
                      if (s.billingPeriod != null) {
                        config.billingPeriod = s.billingPeriod;
                      }
                      config.isEnabled = true;
                      await CreditCardManager.instance.saveConfig(config);
                      openSnackbar(
                        SnackbarMessage(
                          title: "Card Settings Synchronized",
                          description:
                              "Statement baseline (${s.totalAmountDue != null ? '$currency${s.totalAmountDue!.toStringAsFixed(2)}' : 'updated'}), limit, and dates saved.",
                          icon: Icons.check_circle_rounded,
                        ),
                      );
                    },
                  ),
              ],
            ),
            if (s.billingPeriod != null) ...[
              const SizedBox(height: 8),
              TextFont(
                text: "Billing Period: ${s.billingPeriod}",
                fontSize: 11.5,
                textColor: getColor(context, "textLight"),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (s.statementDate != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFont(
                        text: "Statement Date:",
                        fontSize: 11,
                        textColor: getColor(context, "textLight"),
                      ),
                      TextFont(
                        text: dateFormat.format(s.statementDate!),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ],
                  ),
                if (s.dueDate != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFont(
                        text: "Payment Due Date:",
                        fontSize: 11,
                        textColor: getColor(context, "textLight"),
                      ),
                      TextFont(
                        text:
                            "${dateFormat.format(s.dueDate!)}${gracePeriodDays != null ? ' ($gracePeriodDays days)' : ''}",
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        textColor: Colors.red.shade800,
                      ),
                    ],
                  ),
              ],
            ),
            if (totalDueStr != null || minDueStr != null) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (totalDueStr != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "Total Amount Due:",
                          fontSize: 11,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextFont(
                          text: totalDueStr,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ],
                    ),
                  if (minDueStr != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        TextFont(
                          text: "Minimum Due:",
                          fontSize: 11,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextFont(
                          text: minDueStr,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ],
                    ),
                ],
              ),
            ],
            // Statement Summary Metrics (Previous Dues, Payments, Purchases, Charges)
            if (s.previousStatementDue != null ||
                s.paymentsReceived != null ||
                s.purchasesCurrentCycle != null) ...[
              const Divider(height: 20),
              TextFont(
                text: "Statement Cycle Accounting",
                fontSize: 12,
                fontWeight: FontWeight.bold,
                textColor: getColor(context, "textLight"),
              ),
              const SizedBox(height: 6),
              if (s.previousStatementDue != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text: "Previous Statement Due:",
                        fontSize: 12,
                        textColor: getColor(context, "textLight"),
                      ),
                      TextFont(
                        text:
                            "$currency${s.previousStatementDue!.toStringAsFixed(2)}",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ],
                  ),
                ),
              if (s.paymentsReceived != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text: "Payments / Credits Received:",
                        fontSize: 12,
                        textColor: Colors.green.shade800,
                      ),
                      TextFont(
                        text:
                            "- $currency${s.paymentsReceived!.toStringAsFixed(2)}",
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        textColor: Colors.green.shade800,
                      ),
                    ],
                  ),
                ),
              if (s.purchasesCurrentCycle != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text: "Purchases / Debits (Current Cycle):",
                        fontSize: 12,
                        textColor: getColor(context, "textLight"),
                      ),
                      TextFont(
                        text:
                            "+ $currency${s.purchasesCurrentCycle!.toStringAsFixed(2)}",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ],
                  ),
                ),
              if (s.financeCharges != null && s.financeCharges! > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text: "Finance Charges:",
                        fontSize: 12,
                        textColor: Colors.red.shade700,
                      ),
                      TextFont(
                        text:
                            "+ $currency${s.financeCharges!.toStringAsFixed(2)}",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        textColor: Colors.red.shade700,
                      ),
                    ],
                  ),
                ),
              if (s.gstCharges != null && s.gstCharges! > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextFont(
                        text: "GST / Taxes on Charges:",
                        fontSize: 12,
                        textColor: Colors.red.shade700,
                      ),
                      TextFont(
                        text: "+ $currency${s.gstCharges!.toStringAsFixed(2)}",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        textColor: Colors.red.shade700,
                      ),
                    ],
                  ),
                ),
            ],
            // Credit Limits & Available Balances
            if (s.totalCreditLimit != null ||
                s.availableCreditLimit != null ||
                s.availableCashLimit != null) ...[
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (s.totalCreditLimit != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: "Total Limit:",
                          fontSize: 10.5,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextFont(
                          text:
                              "$currency${s.totalCreditLimit!.toStringAsFixed(0)}",
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ],
                    ),
                  if (s.availableCreditLimit != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        TextFont(
                          text: "Available Credit:",
                          fontSize: 10.5,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextFont(
                          text:
                              "$currency${s.availableCreditLimit!.toStringAsFixed(0)}",
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          textColor: Colors.green.shade800,
                        ),
                      ],
                    ),
                  if (s.availableCashLimit != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        TextFont(
                          text: "Cash Limit:",
                          fontSize: 10.5,
                          textColor: getColor(context, "textLight"),
                        ),
                        TextFont(
                          text:
                              "$currency${s.availableCashLimit!.toStringAsFixed(0)}",
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ],
                    ),
                ],
              ),
            ],
            if (financeChargesStr != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFont(
                        text:
                            "Bank Charged Interest: $financeChargesStr${gstStr != null ? ' + $gstStr GST' : ''} billed this cycle.",
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        textColor: Colors.red.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (s.emiSummaries.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.deepPurple.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.deepPurple.withOpacity(0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.calendar_month_rounded,
                            color: Colors.deepPurple.shade700, size: 18),
                        const SizedBox(width: 6),
                        TextFont(
                          text: "Active Card EMIs (${s.emiSummaries.length}):",
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          textColor: Colors.deepPurple.shade900,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (final emi in s.emiSummaries.take(3))
                      TextFont(
                        text: "• $emi",
                        fontSize: 10,
                        textColor: Colors.deepPurple.shade800,
                        maxLines: 2,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEntryRow(StatementEntry entry) {
    final currency = Provider.of<AllWallets>(context, listen: false)
            .indexedByPk[_selectedWalletPk]?.currency ??
        "";

    final allWallets = Provider.of<AllWallets>(context, listen: false);
    final isTransfer =
        entry.destinationWalletPk != null || entry.isTransferToCash;
    final targetWallet = entry.destinationWalletPk != null
        ? allWallets.indexedByPk[entry.destinationWalletPk]
        : null;

    final isCash = entry.isCashWithdrawal;
    final isDup = entry.duplicateState != DuplicateState.unique;
    final isPendingSms = isDup && entry.matchedSource == 'review_inbox';
    final isDbMatch = isDup && entry.matchedSource == 'database';

    Color accentColor;
    Color bgTint;
    String statusTitle;
    IconData statusIcon;

    if (entry.isCreditCardInterest) {
      accentColor = Colors.red.shade800;
      bgTint = Colors.red.withOpacity(0.08);
      statusTitle = "⚡ Bank Finance Charge / Interest Billed";
      statusIcon = Icons.error_outline_rounded;
    } else if (entry.isCreditCardGst) {
      accentColor = Colors.orange.shade800;
      bgTint = Colors.orange.withOpacity(0.06);
      statusTitle = "🏛️ GST on Finance Charges";
      statusIcon = Icons.receipt_long_rounded;
    } else if (entry.isCreditCardEmi) {
      accentColor = Colors.deepPurple.shade700;
      bgTint = Colors.deepPurple.withOpacity(0.06);
      statusTitle = "📅 Credit Card EMI Installment";
      statusIcon = Icons.calendar_month_rounded;
    } else if (isTransfer) {
      accentColor = Colors.blue.shade800;
      bgTint = Colors.blue.withOpacity(0.06);
      statusTitle =
          "⇄ Transfer to ${targetWallet?.name ?? (entry.isTransferToCash ? 'Cash Wallet' : 'Account')}";
      statusIcon = Icons.compare_arrows_rounded;
    } else if (isCash) {
      accentColor = Colors.amber.shade800;
      bgTint = Colors.amber.withOpacity(0.06);
      statusTitle = "💵 Cash Withdrawal (Manual Cash Control)";
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
                                      text: entry.suggestedSubCategoryName != null &&
                                              entry.suggestedSubCategoryName!.isNotEmpty
                                          ? "${entry.suggestedCategoryName} • ${entry.suggestedSubCategoryName}"
                                          : entry.suggestedCategoryName,
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
