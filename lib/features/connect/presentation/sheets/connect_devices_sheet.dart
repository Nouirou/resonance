import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/utils/uicons.dart';
import 'package:resonance/core/widgets/buttons/resonance_button.dart';
import 'package:resonance/core/widgets/buttons/reusable_hover_icon_button.dart';
import 'package:resonance/core/widgets/inputs/resonance_switch.dart';
import 'package:resonance/core/widgets/overlays/floating_sheet_shell.dart';

import '../../application/connect_client_notifier.dart';
import '../../application/connect_discovery_notifier.dart';
import '../../application/connect_server_notifier.dart';
import '../../domain/models/connect_device.dart';
import '../../infrastructure/storage/connect_paired_devices_store.dart';
import '../dialogs/connect_pin_entry_dialog.dart';
import '../dialogs/connect_qr_pairing_dialog.dart';
import '../widgets/connect_device_tile.dart';

/// Canonical Spotify Connect-style device selector & host control sheet.
class ConnectDevicesSheet extends ConsumerStatefulWidget {
  const ConnectDevicesSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => const ConnectDevicesSheet(),
    );
  }

  @override
  ConsumerState<ConnectDevicesSheet> createState() =>
      _ConnectDevicesSheetState();
}

class _ConnectDevicesSheetState extends ConsumerState<ConnectDevicesSheet> {
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

  @override
  void dispose() {
    try {
      ref.read(connectDiscoveryProvider.notifier).stopScan();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _onDeviceTapped(ConnectDevice device) async {
    final clientState = ref.read(connectClientProvider);
    final clientNotifier = ref.read(connectClientProvider.notifier);

    if (clientState.isActiveRemote &&
        clientState.activeDevice?.id == device.id) {
      await clientNotifier.disconnectFromRemote();
      return;
    }

    // If already paired with token, connect directly
    if (device.isPaired &&
        device.authToken != null &&
        device.authToken!.isNotEmpty) {
      final ok = await clientNotifier.connectToDevice(device);
      if (ok || !mounted) return;
    }

    // Otherwise prompt for 4-digit PIN
    if (!mounted) return;
    await ConnectPinEntryDialog.showForDevice(context, device);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    final store = ref.watch(connectPairedDevicesStoreProvider);
    final serverState = ref.watch(connectServerProvider);
    final discoveryState = ref.watch(connectDiscoveryProvider);
    final clientState = ref.watch(connectClientProvider);
    final isDualMode = ref.watch(isDualPlaybackEnabledProvider);

    final isLocalActive = !clientState.isActiveRemote;

    return FloatingSheetShell(
      maxWidth: 460,
      title: 'Resonance Connect',
      icon: UIcons.regular.devices,
      onClose: () => Navigator.pop(context),
      children: [
        // 1. This Device Card
        _ThisDeviceCard(
          deviceName: store.localDeviceName,
          isDesktop: _isDesktop,
          isActiveOutput: isLocalActive,
          connectedRemoteCount: serverState.connectedClients.length,
          onSelectThisDevice: isLocalActive
              ? null
              : () => ref
                  .read(connectClientProvider.notifier)
                  .disconnectFromRemote(),
        ),

        // 1b. Dual Bottom Progress Bar Toggle (Mobile Remote Mode)
        if (!_isDesktop && clientState.isActiveRemote) ...[
          const SizedBox(height: 10),
          _DualPlaybackToggleCard(
            isEnabled: isDualMode,
            hostName: clientState.activeDevice?.name ?? 'Desktop',
            onToggle: (val) =>
                ref.read(isDualPlaybackEnabledProvider.notifier).setEnabled(val),
          ),
        ],

        // 2. Desktop Host Mode Control Panel (on Desktop platforms)
        if (_isDesktop) ...[
          const SizedBox(height: 12),
          _DesktopHostPanel(
            serverState: serverState,
            onToggle: (val) =>
                ref.read(connectServerProvider.notifier).setHostEnabled(val),
            onShowQr: () => ConnectQrPairingDialog.show(context),
          ),
        ],

        const SizedBox(height: 16),

        // 3. Discovered / Paired Devices Section Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'AVAILABLE DEVICES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (discoveryState.isScanning) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: primary,
                    ),
                  ),
                ],
              ],
            ),
            ReusableHoverIconButton(
              icon: UIcons.regular.refresh,
              tooltip: 'Scan LAN',
              iconSize: 14,
              padding: 6,
              onTap: () =>
                  ref.read(connectDiscoveryProvider.notifier).startScan(),
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (discoveryState.availableDevices.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: isDark ? 0.25 : 0.4,
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(
                  alpha: isDark ? 0.08 : 0.05,
                ),
              ),
            ),
            child: Column(
              children: [
                Icon(
                  UIcons.regular.wifi,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  discoveryState.isScanning
                      ? 'Searching local network for Resonance Desktop...'
                      : 'No Desktop hosts found on local network',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Ensure both devices are on the same Wi-Fi/LAN, or connect via QR / IP below.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
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

        // 4. Quick Action Bar (Scan QR Code on Mobile + Enter IP Manually)
        Row(
          children: [
            if (!_isDesktop) ...[
              Expanded(
                child: ResonanceButton(
                  label: 'Scan QR',
                  icon: UIcons.regular.qrcode,
                  style: ResonanceButtonStyle.primary,
                  isFullWidth: true,
                  onPressed: () => ConnectPinEntryDialog.showManualEntry(
                    context,
                    qrMode: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: ResonanceButton(
                label: 'Enter IP / PIN',
                icon: UIcons.regular.keyboard,
                style: ResonanceButtonStyle.secondary,
                isFullWidth: true,
                onPressed: () => ConnectPinEntryDialog.showManualEntry(context),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ThisDeviceCard extends StatelessWidget {
  final String deviceName;
  final bool isDesktop;
  final bool isActiveOutput;
  final int connectedRemoteCount;
  final VoidCallback? onSelectThisDevice;

  const _ThisDeviceCard({
    required this.deviceName,
    required this.isDesktop,
    required this.isActiveOutput,
    required this.connectedRemoteCount,
    this.onSelectThisDevice,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onSelectThisDevice,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isActiveOutput
                ? primary.withValues(alpha: isDark ? 0.16 : 0.10)
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: isDark ? 0.30 : 0.45,
                  ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActiveOutput
                  ? primary.withValues(alpha: 0.40)
                  : theme.colorScheme.outline.withValues(
                      alpha: isDark ? 0.10 : 0.06,
                    ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isActiveOutput
                      ? primary.withValues(alpha: 0.22)
                      : theme.colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isDesktop
                      ? UIcons.regular.computer
                      : UIcons.regular.mobile,
                  size: 18,
                  color: isActiveOutput
                      ? primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$deviceName (This Device)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: isActiveOutput
                            ? primary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      connectedRemoteCount > 0
                          ? 'Playing here · $connectedRemoteCount remote${connectedRemoteCount == 1 ? '' : 's'} connected'
                          : isActiveOutput
                              ? 'Listening on this device'
                              : 'Tap to switch back to local playback',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: isActiveOutput
                            ? primary.withValues(alpha: 0.85)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (isActiveOutput)
                Icon(
                  UIcons.regular.volume,
                  size: 16,
                  color: primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopHostPanel extends StatelessWidget {
  final ConnectServerState serverState;
  final ValueChanged<bool> onToggle;
  final VoidCallback onShowQr;

  const _DesktopHostPanel({
    required this.serverState,
    required this.onToggle,
    required this.onShowQr,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.32 : 0.48,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(
            alpha: isDark ? 0.10 : 0.06,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Allow Remote Control (Host Mode)',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      serverState.isRunning
                          ? '${serverState.endpoint} · PIN: ${serverState.pairingPin}'
                          : 'Disabled',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        fontFamily: serverState.isRunning ? 'monospace' : null,
                        color: serverState.isRunning
                            ? primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ResonanceSwitch(
                value: serverState.isEnabled,
                onChanged: onToggle,
              ),
            ],
          ),
          if (serverState.isRunning) ...[
            const SizedBox(height: 12),
            ResonanceButton(
              label: 'Show QR Code & Pairing PIN',
              icon: UIcons.regular.qrcode,
              style: ResonanceButtonStyle.secondary,
              isFullWidth: true,
              onPressed: onShowQr,
            ),
          ],
        ],
      ),
    );
  }
}

class _DualPlaybackToggleCard extends StatelessWidget {
  final bool isEnabled;
  final String hostName;
  final ValueChanged<bool> onToggle;

  const _DualPlaybackToggleCard({
    required this.isEnabled,
    required this.hostName,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isEnabled
            ? primary.withValues(alpha: isDark ? 0.14 : 0.08)
            : theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: isDark ? 0.28 : 0.42,
              ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isEnabled
              ? primary.withValues(alpha: 0.35)
              : theme.colorScheme.outline.withValues(
                  alpha: isDark ? 0.10 : 0.06,
                ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: isEnabled
                  ? primary.withValues(alpha: 0.20)
                  : theme.colorScheme.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              UIcons.regular.layers,
              size: 17,
              color: isEnabled
                  ? primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dual Progress Bar (Play on Phone)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isEnabled
                        ? primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isEnabled
                      ? 'Slideable $hostName bar active above phone player'
                      : 'Play music on this phone while keeping $hostName remote bar',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ResonanceSwitch(
            value: isEnabled,
            onChanged: onToggle,
          ),
        ],
      ),
    );
  }
}
