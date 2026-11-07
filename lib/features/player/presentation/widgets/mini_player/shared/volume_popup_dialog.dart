import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/utils/uicons.dart';
import 'package:resonance/features/connect/application/connect_client_notifier.dart';
import 'package:resonance/features/player/application/providers/audio_provider.dart';

class VolumePopupDialog extends ConsumerWidget {
  final Offset buttonOffset;
  final Size buttonSize;

  const VolumePopupDialog({
    super.key,
    required this.buttonOffset,
    required this.buttonSize,
  });

  static void show({
    required BuildContext context,
    required Offset buttonOffset,
    required Size buttonSize,
  }) {
    showDialog(
      context: context,
      useSafeArea: false,
      builder: (context) => VolumePopupDialog(
        buttonOffset: buttonOffset,
        buttonSize: buttonSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    const double dialogWidth = 300;
    const double dialogHeight = 64;

    double left = buttonOffset.dx - (dialogWidth / 2) + (buttonSize.width / 2);
    final screenWidth = MediaQuery.of(context).size.width;
    if (left < 16) left = 16;
    if (left + dialogWidth > screenWidth - 16) {
      left = screenWidth - dialogWidth - 16;
    }

    double top = buttonOffset.dy - dialogHeight - 16;

    final isRemoteActive = ref.watch(isRemoteControlActiveProvider);
    final localVol = ref.watch(audioProvider.select((s) => s.volume));
    final remoteVol = ref.watch(
      connectClientProvider.select((s) => s.remoteSync?.volume ?? 100.0),
    );
    final double currentVolume = isRemoteActive ? remoteVol : localVol;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: dialogWidth,
                height: dialogHeight,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: _VolumePopupSliderRow(
                  currentVolume: currentVolume,
                  onVolumeChanged: (val) {
                    if (isRemoteActive) {
                      ref.read(connectClientProvider.notifier).setVolume(val);
                    } else {
                      ref.read(audioProvider.notifier).setVolume(val);
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _VolumePopupSliderRow extends StatelessWidget {
  final double currentVolume;
  final ValueChanged<double> onVolumeChanged;

  const _VolumePopupSliderRow({
    required this.currentVolume,
    required this.onVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          Icon(
            currentVolume == 0
                ? UIcons.regular.volume_off
                : currentVolume < 50
                    ? UIcons.regular.volume_down
                    : UIcons.regular.volume,
            color: theme.colorScheme.onSurfaceVariant,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: theme.primaryColor,
                inactiveTrackColor: Colors.grey.withValues(alpha: 0.3),
                thumbColor: theme.primaryColor,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 4,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: currentVolume,
                min: 0.0,
                max: 100.0,
                onChanged: onVolumeChanged,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 32,
            child: Text(
              '${currentVolume.toInt()}%',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
