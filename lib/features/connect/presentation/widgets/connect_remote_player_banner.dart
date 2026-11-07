import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/utils/uicons.dart';

import '../../application/connect_client_notifier.dart';
import '../sheets/connect_devices_sheet.dart';

/// Compact status pill indicating that playback controls are currently routed
/// to a remote Desktop Host over Resonance Connect.
class ConnectRemotePlayerBanner extends ConsumerWidget {
  final bool compact;

  const ConnectRemotePlayerBanner({
    super.key,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clientState = ref.watch(connectClientProvider);
    if (!clientState.isActiveRemote || clientState.activeDevice == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final hostName =
        clientState.remoteSync?.hostName ?? clientState.activeDevice!.name;

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => ConnectDevicesSheet.show(context),
          borderRadius: BorderRadius.circular(compact ? 8 : 12),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 12,
              vertical: compact ? 4 : 7,
            ),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(compact ? 8 : 12),
              border: Border.all(
                color: primary.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  UIcons.regular.computer_speaker,
                  size: compact ? 12 : 14,
                  color: primary,
                ),
                SizedBox(width: compact ? 6 : 8),
                Flexible(
                  child: Text(
                    'Controlling $hostName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: compact ? 11 : 12,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                ),
                SizedBox(width: compact ? 6 : 10),
                GestureDetector(
                  onTap: () => ref
                      .read(connectClientProvider.notifier)
                      .disconnectFromRemote(),
                  child: Icon(
                    UIcons.regular.cross_small,
                    size: compact ? 13 : 15,
                    color: primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
