import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/widgets/inputs/reusable_seek_slider.dart';
import 'package:resonance/features/connect/application/connect_client_notifier.dart';
import 'package:resonance/features/player/application/providers/audio_provider.dart';

/// Progress seek bar anchored at the top edge of [AudioDockedPlayer].
/// Consumes [audioProvider] position and duration (or [connectClientProvider] when in remote mode),
/// rebuilding only this component on position ticks.
class AudioProgressBar extends ConsumerWidget {
  const AudioProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRemoteActive = ref.watch(isDockedBarRemoteProvider);
    final localPos = ref.watch(audioProvider.select((s) => s.position));
    final localDur = ref.watch(audioProvider.select((s) => s.duration));
    final remotePos = ref.watch(
      connectClientProvider.select((s) => s.interpolatedPosition),
    );
    final remoteDur = ref.watch(
      connectClientProvider.select(
        (s) => s.remoteSync?.duration ?? Duration.zero,
      ),
    );

    final pos = isRemoteActive ? remotePos : localPos;
    final dur = isRemoteActive ? remoteDur : localDur;

    return Positioned(
      top: -6.5,
      left: 0,
      right: 0,
      height: 16,
      child: RepaintBoundary(
        child: ReusableSeekSlider(
          value: pos.inMilliseconds.toDouble(),
          max: dur.inMilliseconds.toDouble() > 0 ? dur.inMilliseconds.toDouble() : 1.0,
          height: 16.0,
          trackHeight: 3.0,
          thumbRadius: 5.0,
          onChanged: (_) {},
          onChangeEnd: (val) {
            final target = Duration(milliseconds: val.toInt());
            if (isRemoteActive) {
              ref.read(connectClientProvider.notifier).seek(target);
            } else {
              ref.read(audioProvider.notifier).seek(target);
            }
          },
        ),
      ),
    );
  }
}
