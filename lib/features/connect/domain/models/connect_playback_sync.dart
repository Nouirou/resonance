import '../../../../core/domain/models/media_item.dart';
import '../../../player/data/models/player_enums.dart';

/// Clock-Anchor Playback State Snapshot.
/// Sent on playback state transitions, track changes, seeks, or queue mutations.
/// Allows mobile remote controller to interpolate real-time progress locally
/// without streaming 60 Hz position frames over Wi-Fi.
class ConnectPlaybackSync {
  final MediaItem? currentTrack;
  final bool isPlaying;
  final bool isLoading;
  final int positionMs;
  final int durationMs;
  final int anchorTimestampMs;
  final double playbackRate;
  final double pitch;
  final double volume; // 0.0 to 100.0 matching AudioState.volume
  final LoopMode loopMode;
  final bool isShuffleEnabled;
  final List<MediaItem> queue;
  final int currentIndex;
  final MediaItem? nextTrack;
  final String hostName;
  final bool isHostDiscordRpcActive;

  const ConnectPlaybackSync({
    this.currentTrack,
    this.isPlaying = false,
    this.isLoading = false,
    this.positionMs = 0,
    this.durationMs = 0,
    required this.anchorTimestampMs,
    this.playbackRate = 1.0,
    this.pitch = 0.0,
    this.volume = 100.0,
    this.loopMode = LoopMode.off,
    this.isShuffleEnabled = false,
    this.queue = const [],
    this.currentIndex = -1,
    this.nextTrack,
    this.hostName = 'Desktop',
    this.isHostDiscordRpcActive = false,
  });

  /// Calculates interpolated playback position at [nowMs] using the clock-anchor formula:
  /// displayPosition = positionMs + (nowMs - anchorTimestampMs) * playbackRate
  Duration computePositionAt({int? nowMs}) {
    if (!isPlaying || isLoading) {
      final clamped =
          durationMs > 0 ? positionMs.clamp(0, durationMs) : positionMs;
      return Duration(milliseconds: clamped < 0 ? 0 : clamped);
    }
    final currentEpoch = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final elapsedMs = currentEpoch - anchorTimestampMs;
    if (elapsedMs <= 0) {
      return Duration(milliseconds: positionMs < 0 ? 0 : positionMs);
    }
    final advancedMs = positionMs + (elapsedMs * playbackRate).round();
    final clampedMs =
        durationMs > 0 ? advancedMs.clamp(0, durationMs) : advancedMs;
    return Duration(milliseconds: clampedMs < 0 ? 0 : clampedMs);
  }

  Duration get duration =>
      Duration(milliseconds: durationMs < 0 ? 0 : durationMs);

  Map<String, dynamic> toJson() {
    return {
      'currentTrack': currentTrack?.toJson(includeArt: false),
      'isPlaying': isPlaying,
      'isLoading': isLoading,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'anchorTimestampMs': anchorTimestampMs,
      'playbackRate': playbackRate,
      'pitch': pitch,
      'volume': volume,
      'loopMode': loopMode.name,
      'isShuffleEnabled': isShuffleEnabled,
      'queue': queue.map((t) => t.toJson(includeArt: false)).toList(),
      'currentIndex': currentIndex,
      'nextTrack': nextTrack?.toJson(includeArt: false),
      'hostName': hostName,
      'isHostDiscordRpcActive': isHostDiscordRpcActive,
    };
  }

  factory ConnectPlaybackSync.fromJson(Map<String, dynamic> json) {
    final loopStr = json['loopMode'] as String?;
    final loop = LoopMode.values.firstWhere(
      (m) => m.name == loopStr,
      orElse: () => LoopMode.off,
    );
    final rawQueue = json['queue'] as List<dynamic>? ?? const [];
    return ConnectPlaybackSync(
      currentTrack: json['currentTrack'] != null
          ? MediaItem.fromJson(
              Map<String, dynamic>.from(json['currentTrack'] as Map),
            )
          : null,
      isPlaying: json['isPlaying'] as bool? ?? false,
      isLoading: json['isLoading'] as bool? ?? false,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      anchorTimestampMs: (json['anchorTimestampMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      playbackRate: (json['playbackRate'] as num?)?.toDouble() ?? 1.0,
      pitch: (json['pitch'] as num?)?.toDouble() ?? 0.0,
      volume: (json['volume'] as num?)?.toDouble() ?? 100.0,
      loopMode: loop,
      isShuffleEnabled: json['isShuffleEnabled'] as bool? ?? false,
      queue: rawQueue
          .map(
            (e) => MediaItem.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      currentIndex: (json['currentIndex'] as num?)?.toInt() ?? -1,
      nextTrack: json['nextTrack'] != null
          ? MediaItem.fromJson(
              Map<String, dynamic>.from(json['nextTrack'] as Map),
            )
          : null,
      hostName: json['hostName'] as String? ?? 'Desktop',
      isHostDiscordRpcActive:
          json['isHostDiscordRpcActive'] as bool? ?? false,
    );
  }
}

