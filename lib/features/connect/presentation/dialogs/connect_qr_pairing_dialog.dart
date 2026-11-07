import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:resonance/core/utils/uicons.dart';
import 'package:resonance/core/widgets/buttons/resonance_button.dart';
import 'package:resonance/core/widgets/buttons/reusable_hover_icon_button.dart';
import 'package:resonance/core/widgets/overlays/floating_sheet_shell.dart';
import 'package:resonance/features/settings/application/notification_provider.dart';

import '../../application/connect_server_notifier.dart';

/// Desktop modal displaying the 4-digit pairing PIN, LAN IP:Port endpoint,
/// QR code (`resonance://connect?...`), and connected/trusted client list.
class ConnectQrPairingDialog extends ConsumerWidget {
  const ConnectQrPairingDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => const ConnectQrPairingDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverState = ref.watch(connectServerProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return FloatingSheetShell(
      maxWidth: 440,
      title: 'Pair Mobile Device',
      icon: UIcons.regular.qrcode,
      onClose: () => Navigator.pop(context),
      children: [
        Text(
          'Scan this QR code from Resonance on your phone, or enter the 4-digit PIN when selecting "${serverState.hostName}" on the same Wi-Fi / LAN.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: RepaintBoundary(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: primary.withValues(alpha: 0.25),
                  width: 2,
                ),
              ),
              child: QrImageView(
                data: serverState.qrConnectUri,
                version: QrVersions.auto,
                size: 185,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: isDark ? 0.35 : 0.5,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(
                alpha: isDark ? 0.1 : 0.06,
              ),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'PAIRING PIN',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    serverState.pairingPin.split('').join(' '),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                      color: primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Divider(
                height: 1,
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'HOST ADDRESS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        serverState.endpoint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
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
                            ClipboardData(text: serverState.endpoint),
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
        ),
        const SizedBox(height: 12),
        ResonanceButton(
          label: 'Rotate PIN & QR Token',
          icon: UIcons.regular.refresh,
          style: ResonanceButtonStyle.secondary,
          isFullWidth: true,
          onPressed: () {
            ref.read(connectServerProvider.notifier).regeneratePinAndQrToken();
          },
        ),
        if (serverState.trustedClients.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'TRUSTED REMOTES (${serverState.trustedClients.length})',
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.0,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ...serverState.trustedClients.map((client) {
            final isLive = serverState.connectedClients
                .any((s) => s.clientId == client.clientId);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: isDark ? 0.25 : 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      UIcons.regular.mobile,
                      size: 16,
                      color: isLive
                          ? primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isLive
                            ? '${client.clientName} (Active)'
                            : client.clientName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isLive
                              ? primary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    ReusableHoverIconButton(
                      icon: UIcons.regular.trash,
                      tooltip: 'Revoke access',
                      iconSize: 13,
                      padding: 5,
                      onTap: () {
                        ref
                            .read(connectServerProvider.notifier)
                            .revokeClient(client.clientId);
                      },
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}
