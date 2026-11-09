import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide TextInput;
import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/localSync/localSyncClient.dart';
import 'package:budget/struct/localSync/localSyncServer.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/qrCodeWidget.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';

void openLocalSyncModal(BuildContext context) {
  openBottomSheet(
    context,
    const LocalSyncModal(),
  );
}

class LocalSyncModal extends StatefulWidget {
  const LocalSyncModal({Key? key}) : super(key: key);

  @override
  State<LocalSyncModal> createState() => _LocalSyncModalState();
}

class _LocalSyncModalState extends State<LocalSyncModal> {
  late TextEditingController _hostController;
  late TextEditingController _tokenController;
  bool _isServerRunning = LocalSyncServerImplementation.isRunning;
  List<String> _serverIps = [];
  int _selectedIpIndex = 0;
  String _serverToken = "";
  bool _isSyncing = false;
  String? _syncStatusMessage;
  bool? _lastSyncSuccess;

  @override
  void initState() {
    super.initState();
    final savedHost =
        sharedPreferences.getString("localSync_targetHost") ?? "";
    String savedToken =
        sharedPreferences.getString("localSync_targetToken") ?? "";
    if (savedToken.length > 8) {
      savedToken = "";
      sharedPreferences.remove("localSync_targetToken");
    }
    _hostController = TextEditingController(text: savedHost);
    _tokenController = TextEditingController(text: savedToken);
    _serverToken = LocalSyncServerImplementation.getOrGenerateSecurityToken();
    _loadServerStatus();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadServerStatus() async {
    final ips = await LocalSyncServerImplementation.getLocalIpAddresses();
    if (mounted) {
      setState(() {
        _serverIps = ips;
        _isServerRunning = LocalSyncServerImplementation.isRunning;
        _serverToken =
            LocalSyncServerImplementation.getOrGenerateSecurityToken();
      });
    }
  }

  Future<void> _toggleServer(bool value) async {
    if (value) {
      final success = await LocalSyncServerImplementation.startServer();
      if (!success) {
        openSnackbar(
          SnackbarMessage(
            title: "Failed to start local sync server on port 8765",
            icon: Icons.error_outline,
          ),
        );
      }
    } else {
      await LocalSyncServerImplementation.stopServer();
    }
    await _loadServerStatus();
  }

  void _showEditPinDialog() {
    final pinController = TextEditingController(text: _serverToken);
    openPopup(
      context,
      title: "Set Custom Security PIN",
      description:
          "Enter a memorable PIN (e.g. 1234 or 849201) so you can easily type it on other devices:",
      onSubmitLabel: "Save PIN",
      onSubmit: () {
        final newPin = pinController.text.trim();
        if (newPin.isNotEmpty) {
          LocalSyncServerImplementation.setSecurityToken(newPin);
          setState(() {
            _serverToken = newPin;
          });
          openSnackbar(
            SnackbarMessage(
              title: "Custom PIN saved!",
              icon: Icons.check_circle_outline,
            ),
          );
        }
        popRoute(context);
      },
      onCancelLabel: "Cancel",
      onCancel: () => popRoute(context),
      beforeDescriptionWidget: TextInput(
        labelText: "Security PIN (e.g. 1234)",
        controller: pinController,
        padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
      ),
    );
  }

  Future<void> _performSync() async {
    final host = _hostController.text.trim();
    final token = _tokenController.text.trim();

    if (host.isEmpty) {
      setState(() {
        _syncStatusMessage = "Please enter the Sync Host IP address.";
        _lastSyncSuccess = false;
      });
      return;
    }

    if (token.isEmpty) {
      setState(() {
        _syncStatusMessage =
            "Security Token / PIN required. Enter or scan the pairing token shown on the host device.";
        _lastSyncSuccess = false;
      });
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncStatusMessage = "Connecting securely to $host:8765...";
      _lastSyncSuccess = null;
    });

    await sharedPreferences.setString("localSync_targetHost", host);
    await sharedPreferences.setString("localSync_targetToken", token);

    final result = await LocalSyncClient.syncWithServer(
      host: host,
      port: 8765,
      token: token,
    );

    if (mounted) {
      setState(() {
        _isSyncing = false;
        _lastSyncSuccess = result.success;
        if (result.success) {
          _syncStatusMessage =
              "Authenticated sync complete! Sent ${result.itemsSent} items, received ${result.itemsReceived} items.";
        } else {
          _syncStatusMessage =
              "${result.errorMessage ?? 'Connection error'}";
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 28,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFont(
                        text: "Secure Wi-Fi Peer Sync",
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      TextFont(
                        text:
                            "Token-authenticated, direct sync between trusted devices on your local Wi-Fi",
                        fontSize: 13,
                        textColor: getColor(context, "textLight"),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (kIsWeb) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 18),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.phone_android_rounded,
                        size: 32, color: theme.colorScheme.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const TextFont(
                            text: "Sync Desktop Web with Mobile Phone",
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          const SizedBox(height: 4),
                          TextFont(
                            text:
                                "1. Open Cashew on your phone -> Settings -> Local Wi-Fi Sync.\n"
                                "2. Turn ON 'Run Sync Server' (shows IP & PIN).\n"
                                "3. Enter your phone's IP and 4-6 digit PIN below, then tap 'Sync Now'.",
                            fontSize: 12,
                            maxLines: 4,
                            textColor: getColor(context, "textLight"),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Center(
                child: QrCodeDisplay(
                  data: Uri.base.toString(),
                  size: 160,
                  label: "Scan with Phone Camera to Open this Web Link on Mobile",
                ),
              ),
              const SizedBox(height: 18),
            ],

            // Server Section (Native only, not web)
            if (!kIsWeb) ...[
              SettingsContainerSwitch(
                title: "Run Sync Server on this Device",
                description: _isServerRunning
                    ? "Active & Protected on port 8765"
                    : "Allow trusted phones and desktops to sync with this device",
                icon: Icons.shield_rounded,
                initialValue: _isServerRunning,
                onSwitched: _toggleServer,
              ),
              if (_isServerRunning && _serverIps.isNotEmpty) ...[
                const SizedBox(height: 14),
                Center(
                  child: QrCodeDisplay(
                    data:
                        "http://${_serverIps[_selectedIpIndex.clamp(0, _serverIps.length - 1)]}:8765?token=$_serverToken",
                    size: 160,
                    label: "Scan with Phone Camera to Auto-Authenticate",
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const TextFont(
                            text: "Security Pairing PIN:",
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          Row(
                            children: [
                              InkWell(
                                onTap: _showEditPinDialog,
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_rounded,
                                        size: 15,
                                        color: theme.colorScheme.primary),
                                    const SizedBox(width: 4),
                                    Text(
                                      "Edit PIN",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _serverToken =
                                        LocalSyncServerImplementation
                                            .regenerateSecurityToken();
                                  });
                                  openSnackbar(
                                    SnackbarMessage(
                                      title:
                                          "New security PIN generated. Old pairings revoked.",
                                      icon: Icons.refresh_rounded,
                                    ),
                                  );
                                },
                                child: Row(
                                  children: [
                                    Icon(Icons.refresh_rounded,
                                        size: 15,
                                        color: theme.colorScheme.primary),
                                    const SizedBox(width: 4),
                                    Text(
                                      "New PIN",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        _serverToken,
                        style: TextStyle(
                          fontSize: 22,
                          letterSpacing: 2,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                          fontFamily: "Courier",
                        ),
                      ),
                      const Divider(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const TextFont(
                            text: "Sync Server Address:",
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          InkWell(
                            onTap: () {
                              final ip = _serverIps[
                                  _selectedIpIndex.clamp(0, _serverIps.length - 1)];
                              copyToClipboard("http://$ip:8765?token=$_serverToken");
                              openSnackbar(
                                SnackbarMessage(
                                  title: "Pairing link copied to clipboard!",
                                  icon: Icons.copy_rounded,
                                ),
                              );
                            },
                            child: Row(
                              children: [
                                Icon(Icons.copy_rounded,
                                    size: 14,
                                    color: theme.colorScheme.primary),
                                const SizedBox(width: 4),
                                Text(
                                  "Copy Link",
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      for (int i = 0; i < _serverIps.length; i++)
                        InkWell(
                          onTap: () {
                            setState(() {
                              _selectedIpIndex = i;
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Icon(
                                  _selectedIpIndex == i
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 16,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                SelectableText(
                                  "http://${_serverIps[i]}:8765",
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
                                    fontFamily: "Courier",
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],

            // Client Connect Section
            TextFont(
              text: "Sync with Another Device",
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
            const SizedBox(height: 8),
            TextFont(
              text:
                  "Enter the host IP and the pairing token, or paste a link/scan the QR code:",
              fontSize: 13,
              textColor: getColor(context, "textLight"),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextInput(
                    labelText: "Host IP (e.g. 192.168.1.15)",
                    controller: _hostController,
                    icon: Icons.devices_rounded,
                    padding: EdgeInsetsDirectional.zero,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: "Paste Link / Token from Clipboard",
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primaryContainer,
                  ),
                  icon: const Icon(Icons.content_paste_rounded, size: 20),
                  onPressed: () async {
                    final data =
                        await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null && data!.text!.isNotEmpty) {
                      final raw = data.text!.trim();
                      final token =
                          LocalSyncClient.extractTokenFromInput(raw);
                      if (token != null) {
                        _tokenController.text = token;
                      }
                      var clean = raw;
                      if (clean.contains("?")) clean = clean.split("?")[0];
                      if (clean.startsWith("http://")) clean = clean.substring(7);
                      if (clean.startsWith("https://")) clean = clean.substring(8);
                      if (clean.contains(":")) clean = clean.split(":")[0];
                      if (clean.contains("/")) clean = clean.split("/")[0];
                      setState(() {
                        _hostController.text = clean;
                      });
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextInput(
              labelText: "Security Pairing PIN / Token (e.g. 1234)",
              controller: _tokenController,
              icon: Icons.vpn_key_rounded,
              padding: EdgeInsetsDirectional.zero,
            ),
            const SizedBox(height: 16),

            if (_syncStatusMessage != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _lastSyncSuccess == true
                      ? Colors.green.withOpacity(0.15)
                      : (_lastSyncSuccess == false
                          ? Colors.red.withOpacity(0.15)
                          : theme.colorScheme.surfaceVariant),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _lastSyncSuccess == true
                          ? Icons.check_circle_outline
                          : (_lastSyncSuccess == false
                              ? Icons.error_outline
                              : Icons.sync),
                      color: _lastSyncSuccess == true
                          ? Colors.green
                          : (_lastSyncSuccess == false
                              ? Colors.red
                              : theme.colorScheme.primary),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFont(
                        text: _syncStatusMessage!,
                        fontSize: 13,
                        maxLines: 4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            Button(
              label: _isSyncing ? "Authenticating & Syncing..." : "Sync Now",
              icon: Icons.sync_lock_rounded,
              expandedLayout: true,
              disabled: _isSyncing,
              onTap: _performSync,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}
