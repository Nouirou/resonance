import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:resonance/core/application/providers/window_lifecycle_provider.dart';
import '../data/models/lyric_line.dart';
import '../../connect/application/connect_client_notifier.dart';
import '../../player/application/providers/audio_provider.dart';
import '../../library/application/library_provider.dart';
import '../../library/data/models/media_item.dart';
import '../data/repositories/lyrics_repository.dart';

/// Resolves the track currently inspected by NowPlayingScreen / LyricsScreen
/// (remote Desktop Host track when [isOverlayRemoteTargetProvider] is true,
/// or local Android track when false).
final activeOverlayTrackProvider = Provider<MediaItem?>((ref) {
  final isRemoteTarget = ref.watch(isOverlayRemoteTargetProvider);
  final localTrack = ref.watch(audioProvider.select((s) => s.currentTrack));
  if (!isRemoteTarget) return localTrack;
  final remoteTrack = ref.watch(
    connectClientProvider.select((s) => s.remoteSync?.currentTrack),
  );
  return remoteTrack ?? localTrack;
});

class LyricsState {
  final List<LyricLine> lyrics;
  final bool isLoading;
  final String? error;
  final bool isVideoSynced;

  LyricsState({
    this.lyrics = const [],
    this.isLoading = false,
    this.error,
    this.isVideoSynced = false,
  });

  LyricsState copyWith({
    List<LyricLine>? lyrics,
    bool? isLoading,
    String? error,
    bool? isVideoSynced,
  }) {
    return LyricsState(
      lyrics: lyrics ?? this.lyrics,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      isVideoSynced: isVideoSynced ?? this.isVideoSynced,
    );
  }
}

class LyricsNotifier extends Notifier<LyricsState> {
  String? _lastLoadingPath;

  @override
  LyricsState build() {
    ref.listen<MediaItem?>(activeOverlayTrackProvider, (previous, currTrack) {
      if (currTrack == null) {
        _lastLoadingPath = null;
        state = LyricsState();
        return;
      }

      final effectiveId =
          '${currTrack.id ?? currTrack.path}_${currTrack.title}_${currTrack.artist}';
      if (effectiveId != _lastLoadingPath) {
        _lastLoadingPath = effectiveId;
        _loadLyrics(currTrack, effectiveId);
      }
    });

    ref.listen(libraryProvider.select((s) => s.lyricsFolderPath), (
      previous,
      current,
    ) {
      final track = ref.read(activeOverlayTrackProvider);
      if (track != null) {
        final effectiveId =
            '${track.id ?? track.path}_${track.title}_${track.artist}';
        _lastLoadingPath = effectiveId;
        _loadLyrics(track, effectiveId);
      }
    });

    final initialTrack = ref.read(activeOverlayTrackProvider);
    if (initialTrack != null) {
      final effectiveId =
          '${initialTrack.id ?? initialTrack.path}_${initialTrack.title}_${initialTrack.artist}';
      _lastLoadingPath = effectiveId;
      Future.microtask(
        () => _loadLyrics(initialTrack, effectiveId),
      );
    }

    return LyricsState();
  }

  Future<void> _loadLyrics(MediaItem track, String requestKey) async {
    state = state.copyWith(
      lyrics: [],
      isLoading: true,
      error: null,
      isVideoSynced: false,
    );

    try {
      final repo = ref.read(lyricsRepositoryProvider);
      final lyricsFolderPath = ref.read(libraryProvider).lyricsFolderPath;

      final result = await repo.getLyrics(
        track,
        lyricsFolderPath: lyricsFolderPath,
      );

      if (_lastLoadingPath == requestKey) {
        state = state.copyWith(
          lyrics: result.lines,
          isVideoSynced: result.isVideoSynced,
          isLoading: false,
        );
      }
    } catch (e) {
      if (_lastLoadingPath == requestKey) {
        state = state.copyWith(error: e.toString(), isLoading: false);
      }
    }
  }

  /// Reloads lyrics for the current active track (used when background sync finishes).
  void refresh() {
    final track = ref.read(activeOverlayTrackProvider);
    if (track != null) {
      final effectiveId =
          '${track.id ?? track.path}_${track.title}_${track.artist}';
      _lastLoadingPath = effectiveId;
      _loadLyrics(track, effectiveId);
    }
  }
}

final lyricsProvider = NotifierProvider<LyricsNotifier, LyricsState>(() {
  return LyricsNotifier();
});

final adjustedLyricsPositionProvider = Provider.autoDispose<Duration>((ref) {
  final isRemoteTarget = ref.watch(isOverlayRemoteTargetProvider);
  final localPosition = ref.watch(audioProvider.select((s) => s.position));
  final remotePosition = ref.watch(
    connectClientProvider.select((s) => s.interpolatedPosition),
  );
  final position = isRemoteTarget ? remotePosition : localPosition;

  final offset = ref.watch(
    activeOverlayTrackProvider.select(
      (t) => t?.lyricsOffset ?? Duration.zero,
    ),
  );
  final hasLyrics =
      ref.watch(lyricsProvider.select((s) => s.lyrics.isNotEmpty));

  if (!hasLyrics) return position;
  return position + offset;
});

final activeLyricIndexProvider = Provider.autoDispose<int>((ref) {
  final isRenderActive = ref.watch(isWindowRenderActiveProvider);
  if (!isRenderActive) return -1;

  final lyricsState = ref.watch(lyricsProvider);
  final lyrics = lyricsState.lyrics;

  if (lyrics.isEmpty) return -1;

  final adjustedPosition = ref.watch(adjustedLyricsPositionProvider);

  int index = -1;
  for (int i = 0; i < lyrics.length; i++) {
    if (adjustedPosition >= lyrics[i].timestamp) {
      index = i;
    } else {
      break;
    }
  }
  return index;
});
