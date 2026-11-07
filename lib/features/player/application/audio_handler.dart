import 'dart:io';
import 'dart:ui';
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ResonanceAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final Player player;
  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onStop;
  VoidCallback? onSkipToNext;
  VoidCallback? onSkipToPrevious;

  bool _isRemoteMode = false;
  bool get isRemoteMode => _isRemoteMode;
  VoidCallback? onRemotePlay;
  VoidCallback? onRemotePause;
  VoidCallback? onRemoteSkipToNext;
  VoidCallback? onRemoteSkipToPrevious;
  void Function(Duration position)? onRemoteSeek;

  ResonanceAudioHandler(this.player) {
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.seek,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: AudioProcessingState.idle,
    ));
    _init();
  }

  void _init() {
    player.stream.playing.listen((playing) {
      if (_isRemoteMode) return;
      final currentProcessing = playbackState.value.processingState;
      if (!playing && currentProcessing == AudioProcessingState.idle) {
        return;
      }
      playbackState.add(playbackState.value.copyWith(
        playing: playing,
        updatePosition: player.state.position,
        speed: player.state.rate,
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.seek,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: playing
            ? AudioProcessingState.ready
            : (currentProcessing == AudioProcessingState.idle
                ? AudioProcessingState.idle
                : AudioProcessingState.ready),
      ));
    });

    // Emit position update on track change to sync OS MediaSession
    mediaItem.listen((item) {
      if (_isRemoteMode) return;
      if (item != null) {
        playbackState.add(playbackState.value.copyWith(
          updatePosition: player.state.position,
        ));
      }
    });

    player.stream.duration.listen((duration) {
      if (_isRemoteMode) return;
      // duration is NOT sent to SMTC by audio_service_win. On Windows,
      // emitting mediaItem.add() here creates a stale setMediaItem(prevTrack) call
      // during gapless transitions that races with the correct thread.
      if (Platform.isWindows) return;
      if (duration > Duration.zero && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: duration));
      }
    });

    player.stream.buffer.listen((buffer) {
      if (_isRemoteMode) return;
      if (playbackState.value.processingState == AudioProcessingState.idle) {
        return;
      }
      playbackState.add(playbackState.value.copyWith(
        bufferedPosition: buffer,
      ));
    });

    player.stream.completed.listen((completed) {
      if (_isRemoteMode) return;
      if (completed) {
        // Transition to buffering rather than completed to protect Android Foreground Service
        // while the upcoming queue track URL resolves asynchronously in background.
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.buffering,
        ));
      }
    });

    player.stream.buffering.listen((buffering) {
      if (_isRemoteMode) return;
      if (playbackState.value.processingState == AudioProcessingState.idle) {
        return;
      }
      if (buffering) {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.buffering,
        ));
      } else {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
        ));
      }
    });
  }

  /// Synchronizes the Android OS MediaSession Notification and Lockscreen with
  /// the remote Desktop Host's active playback state when in Single Remote Mode.
  void syncRemotePlayback({
    required MediaItem? remoteMediaItem,
    required bool playing,
    required bool loading,
    required Duration position,
    required Duration duration,
    required double speed,
  }) {
    _isRemoteMode = true;
    if (remoteMediaItem != null) {
      final current = mediaItem.value;
      if (current?.id != remoteMediaItem.id ||
          current?.title != remoteMediaItem.title ||
          current?.artist != remoteMediaItem.artist ||
          current?.artUri != remoteMediaItem.artUri ||
          current?.duration != remoteMediaItem.duration) {
        mediaItem.add(remoteMediaItem);
      }
    }
    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      updatePosition: position,
      bufferedPosition: duration,
      speed: speed <= 0 ? 1.0 : speed,
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.seek,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: remoteMediaItem == null
          ? AudioProcessingState.idle
          : (loading
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready),
    ));
  }

  /// Exits remote notification mode and restores the local Android player's
  /// MediaSession notification and lockscreen controls.
  void exitRemoteMode({
    MediaItem? restoredLocalItem,
    required bool localPlaying,
    required Duration localPosition,
    required Duration localDuration,
    required double localSpeed,
  }) {
    if (!_isRemoteMode) return;
    _isRemoteMode = false;
    onRemotePlay = null;
    onRemotePause = null;
    onRemoteSkipToNext = null;
    onRemoteSkipToPrevious = null;
    onRemoteSeek = null;

    if (restoredLocalItem != null) {
      mediaItem.add(restoredLocalItem);
      playbackState.add(playbackState.value.copyWith(
        playing: localPlaying,
        updatePosition: localPosition,
        bufferedPosition: player.state.buffer,
        speed: localSpeed <= 0 ? 1.0 : localSpeed,
        controls: [
          MediaControl.skipToPrevious,
          if (localPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        processingState: AudioProcessingState.ready,
      ));
    } else {
      mediaItem.add(null);
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        updatePosition: Duration.zero,
        processingState: AudioProcessingState.idle,
      ));
    }
  }

  void notifyQueueCompleted() {
    if (_isRemoteMode) return;
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.completed,
    ));
  }

  @override
  Future<void> onNotificationDeleted() async {
    // When notification is swiped or dismissed on Android, pause playback
    // instead of stopping and unloading libmpv media via player.stop().
    await pause();
  }

  @override
  Future<void> play() async {
    if (_isRemoteMode && onRemotePlay != null) {
      onRemotePlay!();
      return;
    }
    if (onPlay != null) {
      onPlay!();
    } else {
      await player.play();
    }
  }

  @override
  Future<void> pause() async {
    if (_isRemoteMode && onRemotePause != null) {
      onRemotePause!();
      return;
    }
    if (onPause != null) {
      onPause!();
    } else {
      await player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
    if (_isRemoteMode && onRemoteSeek != null) {
      onRemoteSeek!(position);
      return;
    }
    await player.seek(position);
  }

  @override
  Future<void> stop() async {
    if (_isRemoteMode && onRemotePause != null) {
      onRemotePause!();
      return;
    }
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    if (onStop != null) {
      onStop!();
    } else {
      await player.stop();
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_isRemoteMode && onRemoteSkipToNext != null) {
      onRemoteSkipToNext!();
      return;
    }
    onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_isRemoteMode && onRemoteSkipToPrevious != null) {
      onRemoteSkipToPrevious!();
      return;
    }
    onSkipToPrevious?.call();
  }
}

final audioHandlerProvider = Provider<ResonanceAudioHandler>((ref) {
  throw UnimplementedError('audioHandlerProvider must be overridden in main.dart');
});
