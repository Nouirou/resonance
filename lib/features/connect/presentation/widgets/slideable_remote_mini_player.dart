import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/overlay_provider.dart';
import '../../../../core/utils/uicons.dart';
import '../../../../core/widgets/media/media_artwork_widget.dart';
import '../../application/connect_client_notifier.dart';

/// Secondary bottom progress bar rendered above [DockedMiniPlayer] when
/// Dual Progress Bar Mode ([isDualPlaybackEnabledProvider]) is active.
///
/// Always bound to the remote Desktop Host ([connectClientProvider]):
/// - Swipe Right (or tap `›`): shrinks to a compact edge pill on the right.
/// - Swipe Left (or tap pill): expands left to full width.
/// - Tap Expanded Bar: sets [dualOverlayTargetProvider] to [PlaybackTarget.remote]
///   and opens [NowPlayingScreen] for the remote Desktop Host.
class SlideableRemoteMiniPlayer extends ConsumerStatefulWidget {
  const SlideableRemoteMiniPlayer({super.key});

  @override
  ConsumerState<SlideableRemoteMiniPlayer> createState() =>
      _SlideableRemoteMiniPlayerState();
}

class _SlideableRemoteMiniPlayerState
    extends ConsumerState<SlideableRemoteMiniPlayer> {
  bool _isShrunkRight = false;
  double _dragDeltaX = 0.0;

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _openRemoteNowPlaying() {
    ref
        .read(dualOverlayTargetProvider.notifier)
        .setTarget(PlaybackTarget.remote);
    ref.read(nowPlayingOverlayProvider.notifier).setVisible(true);
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _dragDeltaX = 0.0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    _dragDeltaX += details.delta.dx;
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final vx = details.primaryVelocity ?? 0.0;
    if (!_isShrunkRight && (vx > 180 || _dragDeltaX > 36)) {
      setState(() => _isShrunkRight = true);
    } else if (_isShrunkRight && (vx < -180 || _dragDeltaX < -28)) {
      setState(() => _isShrunkRight = false);
    }
    _dragDeltaX = 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final isRemoteActive = ref.watch(isRemoteControlActiveProvider);
    final isDualMode = ref.watch(isDualPlaybackEnabledProvider);
    if (!isRemoteActive || !isDualMode) {
      return const SizedBox.shrink();
    }

    final sync = ref.watch(connectClientProvider.select((s) => s.remoteSync));
    final position = ref.watch(
      connectClientProvider.select((s) => s.interpolatedPosition),
    );
    final hostName = ref.watch(
      connectClientProvider
          .select((s) => s.activeDevice?.name ?? s.remoteSync?.hostName ?? 'Desktop'),
    );

    final track = sync?.currentTrack;
    final duration = sync?.duration ?? Duration.zero;
    final isPlaying = sync?.isPlaying ?? false;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final screenWidth = MediaQuery.sizeOf(context).width;

    return GestureDetector(
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment:
            _isShrunkRight ? Alignment.centerRight : Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          width: _isShrunkRight ? 86.0 : (screenWidth - 16.0).clamp(260.0, 900.0),
          height: _isShrunkRight ? 52.0 : 62.0,
          margin: EdgeInsets.only(
            left: _isShrunkRight ? 0 : 8,
            right: 8,
            bottom: 6,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh.withValues(
              alpha: isDark ? 0.96 : 0.98,
            ),
            borderRadius: BorderRadius.circular(_isShrunkRight ? 26 : 16),
            border: Border.all(
              color: primary.withValues(alpha: isDark ? 0.42 : 0.32),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.14),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_isShrunkRight ? 25 : 15),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showShrunkContent =
                    _isShrunkRight || constraints.maxWidth < 220;
                return showShrunkContent
                    ? _buildShrunkPill(
                        context: context,
                        track: track,
                        progress: progress,
                        isPlaying: isPlaying,
                        primary: primary,
                      )
                    : _buildExpandedBar(
                        context: context,
                        track: track,
                        hostName: hostName,
                        position: position,
                        duration: duration,
                        progress: progress,
                        isPlaying: isPlaying,
                        primary: primary,
                      );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShrunkPill({
    required BuildContext context,
    required dynamic track,
    required double progress,
    required bool isPlaying,
    required Color primary,
  }) {
    final theme = Theme.of(context);
    return Material(
      key: const ValueKey('slideable_remote_shrunk_pill'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _isShrunkRight = false),
        onLongPress: _openRemoteNowPlaying,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(
                UIcons.regular.angle_small_left,
                size: 18,
                color: primary,
              ),
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 2.4,
                      backgroundColor: primary.withValues(alpha: 0.18),
                      valueColor: AlwaysStoppedAnimation<Color>(primary),
                    ),
                  ),
                  ClipOval(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: track != null
                          ? MediaArtworkWidget(
                              item: track,
                              width: 28,
                              height: 28,
                              borderRadius: 14,
                            )
                          : Container(
                              color: primary.withValues(alpha: 0.18),
                              child: Icon(
                                UIcons.regular.computer,
                                size: 14,
                                color: primary,
                              ),
                            ),
                    ),
                  ),
                  if (isPlaying)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedBar({
    required BuildContext context,
    required dynamic track,
    required String hostName,
    required Duration position,
    required Duration duration,
    required double progress,
    required bool isPlaying,
    required Color primary,
  }) {
    final theme = Theme.of(context);
    final notifier = ref.read(connectClientProvider.notifier);

    return Stack(
      children: [
        // Main interactive body
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openRemoteNowPlaying,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 6, 0),
                child: Row(
                  children: [
                    // Artwork with Desktop badge
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: track != null
                                ? MediaArtworkWidget(
                                    item: track,
                                    width: 40,
                                    height: 40,
                                    borderRadius: 9,
                                  )
                                : Container(
                                    color: primary.withValues(alpha: 0.14),
                                    child: Icon(
                                      UIcons.regular.computer,
                                      size: 18,
                                      color: primary,
                                    ),
                                  ),
                          ),
                        ),
                        Positioned(
                          right: -3,
                          bottom: -3,
                          child: Container(
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              color: primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.colorScheme.surface,
                                width: 1.5,
                              ),
                            ),
                            child: const Icon(
                              Icons.desktop_windows_rounded,
                              size: 9,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 10),

                    // Track Title + Host & Timer
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track?.title ?? 'No media playing on $hostName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: primary.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  hostName,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  track != null
                                      ? '${track.artist ?? 'Unknown'} • ${_formatDuration(position)} / ${_formatDuration(duration)}'
                                      : 'Tap to open remote player',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Remote Transport Controls
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        UIcons.regular.step_backward,
                        size: 14,
                        color: theme.colorScheme.onSurface,
                      ),
                      onPressed: notifier.skipToPrevious,
                      tooltip: 'Previous on Desktop',
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        isPlaying ? UIcons.solid.pause : UIcons.solid.play,
                        size: 16,
                        color: primary,
                      ),
                      onPressed: notifier.togglePlayPause,
                      tooltip: isPlaying ? 'Pause Desktop' : 'Play Desktop',
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        UIcons.regular.step_forward,
                        size: 14,
                        color: theme.colorScheme.onSurface,
                      ),
                      onPressed: notifier.skipToNext,
                      tooltip: 'Next on Desktop',
                    ),

                    // Shrink-right handle
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        UIcons.regular.angle_small_right,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () => setState(() => _isShrunkRight = true),
                      tooltip: 'Slide to edge',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Top Interactive Remote Seek Bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 6,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (duration.inMilliseconds <= 0) return;
                  final ratio = (details.localPosition.dx /
                          constraints.maxWidth)
                      .clamp(0.0, 1.0);
                  final target = Duration(
                    milliseconds: (duration.inMilliseconds * ratio).round(),
                  );
                  notifier.seek(target);
                },
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    height: 2.5,
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: primary.withValues(alpha: 0.15),
                      valueColor: AlwaysStoppedAnimation<Color>(primary),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

