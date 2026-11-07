import 'package:resonance/core/widgets/widgets.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/utils/formatters.dart';

import 'package:resonance/features/library/data/models/media_item.dart';
import 'package:resonance/features/connect/application/connect_client_notifier.dart';
import 'package:resonance/features/connect/application/connect_server_notifier.dart';
import 'package:resonance/features/connect/presentation/sheets/connect_devices_sheet.dart';
import 'package:resonance/features/player/application/providers/audio_provider.dart';
import 'package:resonance/features/player/presentation/notifiers/mini_player_view_notifier.dart';
import 'package:resonance/features/player/presentation/screens/full_screen_player.dart';
import 'package:resonance/features/player/presentation/widgets/mini_player/shared/volume_popup_dialog.dart';
import 'package:resonance/features/player/presentation/widgets/mini_player/shared/audio_settings_sheet.dart';
import 'package:resonance/features/player/utils/media_action_utils.dart';

import 'package:resonance/core/utils/uicons.dart';

class AudioExtraActions extends ConsumerWidget {
  final MediaItem track;
  final bool isDesktop;

  const AudioExtraActions({
    super.key,
    required this.track,
    this.isDesktop = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRemoteConnected = ref.watch(isRemoteControlActiveProvider);
    final isRemoteActive = ref.watch(isDockedBarRemoteProvider);
    final hasConnectedRemotes = ref.watch(
      connectServerProvider.select((s) => s.connectedClients.isNotEmpty),
    );
    final isConnectHighlighted = isRemoteConnected || hasConnectedRemotes;

    if (!isDesktop) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReusableHoverIconButton(
            icon: UIcons.regular.devices,
            iconSize: 19,
            color: isConnectHighlighted ? Theme.of(context).primaryColor : null,
            tooltip: 'Resonance Connect',
            onTap: () => ConnectDevicesSheet.show(context),
          ),
          ReusableHoverIconButton(
            icon: UIcons.regular.menu_dots,
            iconSize: 20,
            tooltip: 'Media actions',
            onTap: () => MediaActionUtils.showMediaActions(
              context: context,
              ref: ref,
              item: track,
            ),
          ),
        ],
      );
    }

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Consumer(
            builder: (context, ref, _) {
              final localPosSec =
                  ref.watch(audioProvider.select((s) => s.position.inSeconds));
              final localDurSec =
                  ref.watch(audioProvider.select((s) => s.duration.inSeconds));
              final remotePosSec = ref.watch(
                connectClientProvider
                    .select((s) => s.interpolatedPosition.inSeconds),
              );
              final remoteDurSec = ref.watch(
                connectClientProvider.select(
                  (s) => (s.remoteSync?.duration ?? Duration.zero).inSeconds,
                ),
              );
              final posSec = isRemoteActive ? remotePosSec : localPosSec;
              final durSec = isRemoteActive ? remoteDurSec : localDurSec;
              return SizedBox(
                width: 110, // Fixed width to prevent jitter
                child: Text(
                  "${AppFormatters.formatDuration(Duration(seconds: posSec))} / ${AppFormatters.formatDuration(Duration(seconds: durSec))}",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (buttonContext) {
              final localVol = ref.watch(audioProvider.select((s) => s.volume));
              final remoteVol = ref.watch(
                connectClientProvider
                    .select((s) => s.remoteSync?.volume ?? 100.0),
              );
              final v = isRemoteActive ? remoteVol : localVol;
              return ReusableHoverIconButton(
                tooltip: 'Volume',
                icon: v == 0
                    ? UIcons.regular.volume_off
                    : v < 50
                        ? UIcons.regular.volume_down
                        : UIcons.regular.volume,
                iconSize: 20,
                onTap: () {
                  final RenderBox renderBox =
                      buttonContext.findRenderObject() as RenderBox;
                  final offset = renderBox.localToGlobal(Offset.zero);
                  final buttonSize = renderBox.size;

                  VolumePopupDialog.show(
                    context: context,
                    buttonOffset: offset,
                    buttonSize: buttonSize,
                  );
                },
              );
            },
          ),
          ReusableHoverIconButton(
            icon: UIcons.regular.devices,
            iconSize: 20,
            color: isConnectHighlighted ? Theme.of(context).primaryColor : null,
            tooltip: 'Resonance Connect',
            onTap: () => ConnectDevicesSheet.show(context),
          ),
          ReusableHoverIconButton(
            icon: UIcons.regular.settings_sliders,
            iconSize: 20,
            tooltip: 'Audio Settings',
            onTap: () => AudioSettingsSheet.show(context),
          ),
          if (Platform.isWindows)
            Consumer(
              builder: (context, ref, _) {
                final isPopped =
                    ref.watch(miniPlayerPopProvider.select((s) => s.isPopped));
                return ReusableHoverIconButton(
                  icon: isPopped
                      ? UIcons.regular.window_restore
                      : UIcons.regular.window_alt,
                  tooltip: isPopped ? 'Close Miniplayer' : 'Open Miniplayer',
                  onTap: () => BlurTransitionOverlay.run(
                    ref,
                    () async =>
                        ref.read(miniPlayerPopProvider.notifier).togglePop(),
                  ),
                  iconSize: 20,
                );
              },
            ),
          ReusableHoverIconButton(
            icon: UIcons.regular.expand,
            iconSize: 20,
            tooltip: 'Full Screen',
            onTap: () {
              final isPopped = ref.read(miniPlayerPopProvider).isPopped;
              if (isPopped) {
                ref.read(miniPlayerPopProvider.notifier).togglePop();
              }
              BlurTransitionOverlay.start(ref);
              Navigator.of(context, rootNavigator: true).push(
                InstantPageRoute(
                  settings: const RouteSettings(name: '/fullscreen_player'),
                  child: const FullScreenPlayer(),
                ),
              );
            },
          ),
          ReusableHoverIconButton(
            icon: UIcons.regular.menu_dots,
            iconSize: 20,
            tooltip: 'Media actions',
            onTap: () => MediaActionUtils.showMediaActions(
              context: context,
              ref: ref,
              item: track,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }
}
