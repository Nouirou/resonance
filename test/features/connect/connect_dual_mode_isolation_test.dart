import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/core/domain/models/media_item.dart';
import 'package:resonance/features/connect/application/connect_client_notifier.dart';
import 'package:resonance/features/connect/domain/models/connect_device.dart';
import 'package:resonance/features/connect/domain/models/connect_payload.dart';
import 'package:resonance/features/connect/domain/models/connect_playback_sync.dart';
import 'package:resonance/features/connect/infrastructure/server/connect_shelf_server.dart';
import 'package:resonance/features/connect/infrastructure/storage/connect_paired_devices_store.dart';
import 'package:resonance/features/lyrics/application/lyrics_provider.dart';
import 'package:resonance/features/player/application/providers/audio_provider.dart';
import 'package:resonance/features/player/data/models/player_enums.dart';

class _FakeAudioNotifier extends AudioNotifier {
  final AudioState _initial;
  _FakeAudioNotifier(this._initial);

  @override
  AudioState build() => _initial;

  @override
  Future<void> pause() async {
    state = state.copyWith(isPlaying: false);
  }
}

void main() {
  group('Dual Progress Bar Mode & Split Provider State Isolation', () {
    late ConnectPairedDevicesStore store;
    late ConnectShelfServer server;
    late int boundPort;

    final localAndroidTrack = MediaItem(
      id: 'local_android_1',
      path: '/storage/emulated/0/Music/android_song.mp3',
      title: 'Android Local Song',
      artist: 'Phone Artist',
      duration: const Duration(seconds: 200),
      type: 'audio',
    );

    final localAndroidQueue = [
      localAndroidTrack,
      MediaItem(
        id: 'local_android_2',
        path: '/storage/emulated/0/Music/android_song_2.mp3',
        title: 'Android Recommended Next',
        artist: 'Phone Artist 2',
        duration: const Duration(seconds: 185),
        type: 'audio',
      ),
    ];

    final windowsRemoteTrack = MediaItem(
      id: 'win_remote_1',
      path: 'https://music.youtube.com/watch?v=win_remote_1',
      title: 'Windows Desktop Song',
      artist: 'Desktop Artist',
      duration: const Duration(seconds: 240),
      type: 'audio',
    );

    final windowsRemoteQueue = [
      windowsRemoteTrack,
      MediaItem(
        id: 'win_remote_2',
        path: 'https://music.youtube.com/watch?v=win_remote_2',
        title: 'Windows Radio Recommendation 1',
        artist: 'Desktop Artist 2',
        duration: const Duration(seconds: 210),
        type: 'audio',
      ),
      MediaItem(
        id: 'win_remote_3',
        path: 'https://music.youtube.com/watch?v=win_remote_3',
        title: 'Windows Radio Recommendation 2',
        artist: 'Desktop Artist 3',
        duration: const Duration(seconds: 195),
        type: 'audio',
      ),
    ];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      store = ConnectPairedDevicesStore(prefs);

      final initialSync = ConnectPlaybackSync(
        currentTrack: windowsRemoteTrack,
        isPlaying: true,
        positionMs: 30000,
        durationMs: 240000,
        anchorTimestampMs: DateTime.now().millisecondsSinceEpoch,
        playbackRate: 1.0,
        pitch: 0.0,
        volume: 80.0,
        loopMode: LoopMode.all,
        isShuffleEnabled: false,
        queue: windowsRemoteQueue,
        currentIndex: 0,
        nextTrack: windowsRemoteQueue[1],
        hostName: 'Batara-PC',
        isHostDiscordRpcActive: true,
      );

      server = ConnectShelfServer(
        store: store,
        onBuildInitialSync: () => ConnectPayload.sync(initialSync),
      );
      boundPort = await server.start(preferredPort: 52210);
    });

    tearDown(() async {
      await server.stop();
    });

    ProviderContainer createTestContainer() {
      return ProviderContainer(
        overrides: [
          connectPairedDevicesStoreProvider.overrideWithValue(store),
          audioProvider.overrideWith(
            () => _FakeAudioNotifier(
              AudioState(
                currentTrack: localAndroidTrack,
                queue: localAndroidQueue,
                currentIndex: 0,
                isPlaying: true,
                position: const Duration(seconds: 45),
                duration: const Duration(seconds: 200),
              ),
            ),
          ),
        ],
      );
    }

    test(
        'Condition 1-5: Disconnected -> Single Remote -> Dual Mode -> Bar Target Switching -> Disconnect Restoration',
        () async {
      final container = createTestContainer();
      addTearDown(container.dispose);

      // ── Condition 1: Disconnected State ──
      expect(container.read(isRemoteControlActiveProvider), isFalse);
      expect(container.read(isDockedBarRemoteProvider), isFalse);
      expect(container.read(isOverlayRemoteTargetProvider), isFalse);
      expect(
        container.read(activeOverlayTrackProvider)?.id,
        'local_android_1',
      );

      // ── Condition 2: Connect to Windows (Single Remote Mode) ──
      final hostDevice = ConnectDevice(
        id: store.localDeviceId,
        name: 'Batara-PC',
        ip: '127.0.0.1',
        port: boundPort,
        discoveryMethod: ConnectDiscoveryMethod.manualIp,
        lastSeen: DateTime.now(),
      );

      final connected = await container
          .read(connectClientProvider.notifier)
          .connectToDevice(hostDevice, pin: store.pairingPin);
      expect(connected, isTrue);

      // Wait briefly for initial playbackSync frame over WebSocket
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(container.read(isRemoteControlActiveProvider), isTrue);
      expect(container.read(isDualPlaybackEnabledProvider), isFalse);
      // In Single Remote Mode, both Docked Bar and Overlays target Windows Remote:
      expect(container.read(isDockedBarRemoteProvider), isTrue);
      expect(container.read(isOverlayRemoteTargetProvider), isTrue);
      expect(
        container.read(activeOverlayTrackProvider)?.id,
        'win_remote_1',
      );

      // Local Android player was paused on connect, BUT its track and queue are 100% preserved!
      final localAudioDuringRemote = container.read(audioProvider);
      expect(localAudioDuringRemote.isPlaying, isFalse);
      expect(localAudioDuringRemote.currentTrack?.id, 'local_android_1');
      expect(localAudioDuringRemote.queue.length, 2);
      expect(
        localAudioDuringRemote.queue[1].title,
        'Android Recommended Next',
      );

      // Windows Remote queue is stored separately in connectClientProvider.remoteSync.queue:
      final remoteSync = container.read(connectClientProvider).remoteSync;
      expect(remoteSync, isNotNull);
      expect(remoteSync!.queue.length, 3);
      expect(
        remoteSync.queue[1].title,
        'Windows Radio Recommendation 1',
      );

      // ── Condition 3: User Activates Dual Bottom Progress Bar Mode ──
      container.read(isDualPlaybackEnabledProvider.notifier).setEnabled(true);

      expect(container.read(isDualPlaybackEnabledProvider), isTrue);
      expect(container.read(isRemoteControlActiveProvider), isTrue);
      // Lower DockedMiniPlayer & OS Notification are immediately EXCLUDED from remote (locked to Android Local):
      expect(container.read(isDockedBarRemoteProvider), isFalse);
      // Overlay target defaults to Android Local when Dual Mode is enabled:
      expect(container.read(dualOverlayTargetProvider), PlaybackTarget.local);
      expect(container.read(isOverlayRemoteTargetProvider), isFalse);
      expect(
        container.read(activeOverlayTrackProvider)?.id,
        'local_android_1',
      );

      // ── Condition 4: Clicking Upper Slideable Bar vs Lower Default Bar in Dual Mode ──
      // User clicks Upper Slideable Remote Bar -> opens NowPlayingScreen for Windows Remote:
      container
          .read(dualOverlayTargetProvider.notifier)
          .setTarget(PlaybackTarget.remote);
      expect(container.read(isOverlayRemoteTargetProvider), isTrue);
      expect(
        container.read(activeOverlayTrackProvider)?.id,
        'win_remote_1',
      );
      // Lower DockedMiniPlayer STILL remains locked to Android Local:
      expect(container.read(isDockedBarRemoteProvider), isFalse);

      // User clicks Lower Default Bar -> opens NowPlayingScreen for Android Local:
      container
          .read(dualOverlayTargetProvider.notifier)
          .setTarget(PlaybackTarget.local);
      expect(container.read(isOverlayRemoteTargetProvider), isFalse);
      expect(
        container.read(activeOverlayTrackProvider)?.id,
        'local_android_1',
      );

      // ── Condition 5: Optimistic Remote Updates Preserve All Sync Fields ──
      final clientNotifier = container.read(connectClientProvider.notifier);
      clientNotifier.setVolume(55.0);
      clientNotifier.setSpeed(1.5);
      clientNotifier.setPitch(-3.0);
      clientNotifier.seek(const Duration(seconds: 90));

      final updatedSync = container.read(connectClientProvider).remoteSync!;
      expect(updatedSync.volume, 55.0);
      expect(updatedSync.playbackRate, 1.5);
      expect(updatedSync.pitch, -3.0);
      expect(updatedSync.positionMs, 90000);
      expect(updatedSync.queue.length, 3);
      expect(updatedSync.isHostDiscordRpcActive, isTrue);

      // And Android's local queue & track were NEVER touched by any remote operation:
      expect(container.read(audioProvider).currentTrack?.id, 'local_android_1');
      expect(container.read(audioProvider).queue.length, 2);

      // ── Condition 6: Disconnect Restores Local Mode & Resets Dual Bar State ──
      await clientNotifier.disconnectFromRemote();

      expect(container.read(isRemoteControlActiveProvider), isFalse);
      expect(container.read(isDualPlaybackEnabledProvider), isFalse);
      expect(container.read(isDockedBarRemoteProvider), isFalse);
      expect(container.read(isOverlayRemoteTargetProvider), isFalse);
      expect(
        container.read(activeOverlayTrackProvider)?.id,
        'local_android_1',
      );
    });
  });
}

