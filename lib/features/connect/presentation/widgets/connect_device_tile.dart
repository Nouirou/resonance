import 'package:flutter/material.dart';
import 'package:resonance/core/utils/uicons.dart';
import 'package:resonance/core/widgets/buttons/reusable_hover_icon_button.dart';

import '../../domain/models/connect_device.dart';

/// Displays a discovered or paired Desktop Host row inside the Resonance Connect sheet.
class ConnectDeviceTile extends StatelessWidget {
  final ConnectDevice device;
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback onTap;
  final VoidCallback? onForget;

  const ConnectDeviceTile({
    super.key,
    required this.device,
    required this.isConnected,
    this.isConnecting = false,
    required this.onTap,
    this.onForget,
  });

  String _badgeLabel(ConnectDiscoveryMethod method) {
    switch (method) {
      case ConnectDiscoveryMethod.mdns:
        return 'mDNS';
      case ConnectDiscoveryMethod.udpBeacon:
        return 'LAN';
      case ConnectDiscoveryMethod.qrCode:
        return 'QR';
      case ConnectDiscoveryMethod.manualIp:
        return 'Direct';
      case ConnectDiscoveryMethod.pairedHistory:
        return 'Saved';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isConnecting ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isConnected
                  ? primary.withValues(alpha: isDark ? 0.16 : 0.10)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: isDark ? 0.30 : 0.45,
                    ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isConnected
                    ? primary.withValues(alpha: 0.45)
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
                    color: isConnected
                        ? primary.withValues(alpha: 0.20)
                        : theme.colorScheme.surface.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    UIcons.regular.computer_speaker,
                    size: 18,
                    color: isConnected
                        ? primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              device.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: isConnected
                                    ? primary
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: (device.isPaired
                                      ? primary
                                      : theme.colorScheme.onSurfaceVariant)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              device.isPaired
                                  ? 'Paired · ${_badgeLabel(device.discoveryMethod)}'
                                  : _badgeLabel(device.discoveryMethod),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: device.isPaired
                                    ? primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isConnected
                            ? 'Active Remote · ${device.endpoint}'
                            : isConnecting
                                ? 'Connecting to ${device.endpoint}...'
                                : device.endpoint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: isConnected
                              ? primary.withValues(alpha: 0.85)
                              : theme.colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.75,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isConnecting)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  if (device.isPaired && onForget != null && !isConnected)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ReusableHoverIconButton(
                        icon: UIcons.regular.trash,
                        tooltip: 'Forget device',
                        iconSize: 14,
                        padding: 6,
                        onTap: onForget!,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isConnected
                          ? primary
                          : primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isConnected ? 'Disconnect' : 'Connect',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        color: isConnected ? Colors.white : primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
