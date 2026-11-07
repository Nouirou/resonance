import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/utils/uicons.dart';
import 'package:resonance/core/widgets/buttons/resonance_button.dart';
import 'package:resonance/core/widgets/buttons/reusable_hover_icon_button.dart';
import 'package:resonance/core/widgets/inputs/resonance_switch.dart';
import 'package:resonance/features/settings/application/notification_provider.dart';

import '../../application/connect_client_notifier.dart';
import '../../application/connect_discovery_notifier.dart';
import '../../application/connect_server_notifier.dart';
import '../../domain/models/connect_device.dart';
import '../../infrastructure/storage/connect_paired_devices_store.dart';
import '../dialogs/connect_pin_entry_dialog.dart';
import '../dialogs/connect_qr_pairing_dialog.dart';
import 'connect_device_tile.dart';

/// Full Settings sub-view section for Resonance Connect (Desktop Host & Mobile Remote).
class ConnectSettingsSection extends ConsumerStatefulWidget {
  const ConnectSettingsSection({super.key});

  @override
  ConsumerState<ConnectSettingsSection> createState() =>
      _ConnectSettingsSectionState();
}

class _ConnectSettingsSectionState
    extends ConsumerState<ConnectSettingsSection> {
  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        ref.read(connectDiscoveryProvider.notifier).startScan();
      }
    });
  }

  Future<void> _onDeviceTapped(ConnectDevice device) async {
    final clientState = ref.read(connectClientProvider);
    final clientNotifier = ref.read(connectClientProvider.notifier);

    if (clientState.isActiveRemote &&
        clientState.activeDevice?.id == device.id) {
      await clientNotifier.disconnectFromRemote();
      return;
    }

    if (device.isPaired &&
        device.authToken != null &&
        device.authToken!.isNotEmpty) {
      final ok = await clientNotifier.connectToDevice(device);
      if (ok || !mounted) return;
    }

    if (!mounted) return;
    await ConnectPinEntryDialog.showForDevice(context, device);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = ref.watch(connectPairedDevicesStoreProvider);
    final serverState = ref.watch(connectServerProvider);
    final discoveryState = ref.watch(connectDiscoveryProvider);
    final clientState = ref.watch(connectClientProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Desktop Host Configuration (on Windows/Linux/macOS)
        if (_isDesktop) ...[
          Text(
            'Desktop Host Server',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Material(
            color: theme.colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: Icon(
                    UIcons.regular.computer_speaker,
                    size: 18,
                    color: theme.primaryColor,
                  ),
                  title: const Text(
                    'Allow Remote Control (Host Mode)',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    serverState.isRunning
                        ? 'Listening on ${serverState.endpoint} · ${serverState.connectedClients.length} active remote(s)'
                        : 'Allow phones on the same Wi-Fi/LAN to control playback',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: ResonanceSwitch(
                    value: serverState.isEnabled,
                    onChanged: (val) => ref
                        .read(connectServerProvider.notifier)
                        .setHostEnabled(val),
                  ),
                ),
                if (serverState.isRunning) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '4-DIGIT PAIRING PIN',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    letterSpacing: 1.0,
                                    fontWeight: FontWeight.w700,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  serverState.pairingPin.split('').join(' '),
                                  style:
                                      theme.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: theme.primaryColor,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'LAN ENDPOINT',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    letterSpacing: 1.0,
                                    fontWeight: FontWeight.w700,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SelectableText(
                                      serverState.endpoint,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    ReusableHoverIconButton(
                                      icon: UIcons.regular.copy,
                                      tooltip: 'Copy IP:Port',
                                      iconSize: 13,
                                      padding: 5,
                                      onTap: () {
                                        Clipboard.setData(
                                          ClipboardData(
                                            text: serverState.endpoint,
                                          ),
                                        );
                                        ref
                                            .read(notificationProvider.notifier)
                                            .showNotification(
                                              'Resonance Connect',
                                              'Copied ${serverState.endpoint}',
                                              silentOsNotification: true,
                                            );
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            ResonanceButton(
                              label: 'Show QR Code',
                              icon: UIcons.regular.qrcode,
                              style: ResonanceButtonStyle.primary,
                              onPressed: () =>
                                  ConnectQrPairingDialog.show(context),
                            ),
                            ResonanceButton(
                              label: 'Rotate PIN & QR',
                              icon: UIcons.regular.refresh,
                              style: ResonanceButtonStyle.secondary,
                              onPressed: () => ref
                                  .read(connectServerProvider.notifier)
                                  .regeneratePinAndQrToken(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 2. Trusted / Remembered Mobile Remotes on Desktop
          Text(
            'Remembered Mobile Remotes (${serverState.trustedClients.length})',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Material(
            color: theme.colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
            child: serverState.trustedClients.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Text(
                        'No paired phones yet. Scan the QR code or enter the 4-digit PIN from your phone to pair.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (int i = 0;
                          i < serverState.trustedClients.length;
                          i++) ...[
                        if (i > 0) const Divider(height: 1),
                        Builder(
                          builder: (context) {
                            final client = serverState.trustedClients[i];
                            final activeSession = serverState.connectedClients
                                .where((s) => s.clientId == client.clientId)
                                .firstOrNull;
                            final isOnline = activeSession != null;
                            return ListTile(
                              leading: Icon(
                                UIcons.regular.mobile,
                                size: 18,
                                color: isOnline
                                    ? theme.primaryColor
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              title: Text(
                                client.clientName,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: isOnline
                                      ? theme.primaryColor
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                              subtitle: Text(
                                isOnline
                                    ? 'Connected now (${activeSession.remoteIp})'
                                    : 'Paired · Reconnects automatically without PIN',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isOnline
                                      ? theme.primaryColor
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: ReusableHoverIconButton(
                                icon: UIcons.regular.trash,
                                tooltip: 'Revoke & Forget Phone',
                                iconSize: 15,
                                padding: 6,
                                onTap: () => ref
                                    .read(connectServerProvider.notifier)
                                    .revokeClient(client.clientId),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 24),
        ],

        // 3. Available & Remembered Desktop Hosts (for Mobile & Desktop Client)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'Available & Paired Desktops',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (discoveryState.isScanning) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.primaryColor,
                    ),
                  ),
                ],
              ],
            ),
            ReusableHoverIconButton(
              icon: UIcons.regular.refresh,
              tooltip: 'Scan LAN',
              iconSize: 16,
              padding: 6,
              onTap: () =>
                  ref.read(connectDiscoveryProvider.notifier).startScan(),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'This device: ${store.localDeviceName}. Select a Desktop host below to control its playback remotely.',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),

        if (discoveryState.availableDevices.isEmpty)
          Material(
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    UIcons.regular.wifi,
                    size: 24,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    discoveryState.isScanning
                        ? 'Scanning local Wi-Fi / LAN for Desktop hosts...'
                        : 'No Desktop hosts discovered yet',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Make sure Host Mode is enabled on your Desktop PC, or pair directly using QR Code or IP:Port below.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...discoveryState.availableDevices.map((device) {
            final isConnected = clientState.isActiveRemote &&
                clientState.activeDevice?.id == device.id;
            final isConnecting = clientState.isConnecting &&
                clientState.activeDevice?.id == device.id;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ConnectDeviceTile(
                device: device,
                isConnected: isConnected,
                isConnecting: isConnecting,
                onTap: () => _onDeviceTapped(device),
                onForget: device.isPaired
                    ? () => ref
                        .read(connectDiscoveryProvider.notifier)
                        .removePairedDevice(device.id)
                    : null,
              ),
            );
          }),

        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (!_isDesktop)
              ResonanceButton(
                label: 'Scan Desktop QR Code',
                icon: UIcons.regular.qrcode,
                style: ResonanceButtonStyle.primary,
                onPressed: () => ConnectPinEntryDialog.showManualEntry(
                  context,
                  qrMode: true,
                ),
              ),
            ResonanceButton(
              label: 'Pair via Manual IP & PIN',
              icon: UIcons.regular.keyboard,
              style: ResonanceButtonStyle.secondary,
              onPressed: () => ConnectPinEntryDialog.showManualEntry(context),
            ),
          ],
        ),
      ],
    );
  }
}

