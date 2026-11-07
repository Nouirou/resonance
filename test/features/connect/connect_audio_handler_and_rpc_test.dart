import 'dart:async';
import 'package:audio_service/audio_service.dart' as audio_svc;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/core/data/services/discord_rpc_service.dart';
import 'package:resonance/core/domain/models/media_item.dart';
import 'package:resonance/features/connect/application/connect_client_notifier.dart';
import 'package:resonance/features/connect/domain/models/connect_device.dart';
import 'package:resonance/features/connect/domain/models/connect_payload.dart';
import 'package:resonance/features/connect/domain/models/connect_playback_sync.dart';
import 'package:resonance/features/connect/infrastructure/server/connect_shelf_server.dart';
import 'package:resonance/features/connect/infrastructure/storage/connect_paired_devices_store.dart';
import 'package:resonance/features/player/application/audio_handler.dart';
import 'package:resonance/features/player/application/providers/audio_provider.dart';

class _FakePlayerState implements PlayerState {
  @override
  Duration get position => const Duration(seconds: 12);

  @override
  double get rate => 1.0;

  @override
  Duration get buffer => const Duration(seconds: 30);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerStream implements PlayerStream {
  @override
  final Stream<bool> playing;
  @override
  final Stream<Duration> duration;
  @override
  final Stream<Duration> buffer;
  @override
  final Stream<bool> completed;
  @override
  final Stream<bool> buffering;

  _FakePlayerStream({
    required this.playing,
    required this.duration,
    required this.buffer,
    required this.completed,
    required this.buffering,
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayer implements Player {
  @override
  final PlayerStream stream;

  @override
  final PlayerState state = _FakePlayerState();

  _FakePlayer(this.stream);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDiscordRpcService implements DiscordRpcService {
  int remoteSyncCalls = 0;
  int clearCalls = 0;
  int localUpdateCalls = 0;
  MediaItem? lastSyncedRemoteTrack;

  @override
  bool get isPresenceActive => false;

  @override
  Future<void> syncRemoteTrackPresence(
    MediaItem? track, {
    required Duration position,
    required Duration duration,
    required bool isPlaying,
  }) async {
    remoteSyncCalls++;
    lastSyncedRemoteTrack = track;
  }

  @override
  void clearPresence() {
    clearCalls++;
  }

  @override
  Future<String?> updatePresence(
    MediaItem? track,
    Duration position,
    Duration duration,
    bool isPlaying,
  ) async {
    localUpdateCalls++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  group('ResonanceAudioHandler Remote Notification Sync & Restoration', () {
    late StreamController<bool> playingController;
    late StreamController<Duration> durationController;
    late StreamController<Duration> bufferController;
    late StreamController<bool> completedController;
    late StreamController<bool> bufferingController;
    late ResonanceAudioHandler handler;

    setUp(() {
      playingController = StreamController<bool>.broadcast();
      durationController = StreamController<Duration>.broadcast();
      bufferController = StreamController<Duration>.broadcast();
      completedController = StreamController<bool>.broadcast();
      bufferingController = StreamController<bool>.broadcast();

      final fakeStream = _FakePlayerStream(
        playing: playingController.stream,
        duration: durationController.stream,
        buffer: bufferController.stream,
        completed: completedController.stream,
        buffering: bufferingController.stream,
      );
      final fakePlayer = _FakePlayer(fakeStream);
      handler = ResonanceAudioHandler(fakePlayer);
    });

    tearDown(() async {
      await playingController.close();
      await durationController.close();
      await bufferController.close();
      await completedController.close();
      await bufferingController.close();
    });

    test(
        'syncRemotePlayback updates MediaSession notification and routes lockscreen controls to remote callbacks',
        () async {
      int localPlayCalls = 0;
      int localPauseCalls = 0;
      int localNextCalls = 0;
      int localPrevCalls = 0;

      int remotePlayCalls = 0;
      int remotePauseCalls = 0;
      int remoteNextCalls = 0;
      int remotePrevCalls = 0;
      Duration? remoteSeekTarget;

      handler.onPlay = () => localPlayCalls++;
      handler.onPause = () => localPauseCalls++;
      handler.onSkipToNext = () => localNextCalls++;
      handler.onSkipToPrevious = () => localPrevCalls++;

      handler.onRemotePlay = () => remotePlayCalls++;
      handler.onRemotePause = () => remotePauseCalls++;
      handler.onRemoteSkipToNext = () => remoteNextCalls++;
      handler.onRemoteSkipToPrevious = () => remotePrevCalls++;
      handler.onRemoteSeek = (pos) => remoteSeekTarget = pos;

      final remoteItem = audio_svc.MediaItem(
        id: 'win_song_99',
        title: 'Remote Desktop Anthem',
        artist: 'Chrono • Studio-PC',
        album: 'Studio-PC',
        duration: const Duration(seconds: 215),
        artUri: Uri.parse('http://192.168.1.10:52026/art/win_song_99'),
      );

      handler.syncRemotePlayback(
        remoteMediaItem: remoteItem,
        playing: true,
        loading: false,
        position: const Duration(seconds: 64),
        duration: const Duration(seconds: 215),
        speed: 1.25,
      );

      expect(handler.isRemoteMode, isTrue);
      expect(handler.mediaItem.value?.id, 'win_song_99');
      expect(handler.mediaItem.value?.title, 'Remote Desktop Anthem');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.speed, 1.25);
      expect(
        handler.playbackState.value.processingState,
        audio_svc.AudioProcessingState.ready,
      );

      // Local player stream events must be ignored while in Remote Mode!
      playingController.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(handler.playbackState.value.playing, isTrue);

      // Lockscreen / Bluetooth media controls must route to Remote callbacks, NOT local!
      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.seek(const Duration(seconds: 120));

      expect(remotePlayCalls, 1);
      expect(remotePauseCalls, 1);
      expect(remoteNextCalls, 1);
      expect(remotePrevCalls, 1);
      expect(remoteSeekTarget, const Duration(seconds: 120));

      expect(localPlayCalls, 0);
      expect(localPauseCalls, 0);
      expect(localNextCalls, 0);
      expect(localPrevCalls, 0);

      // Exiting Remote Mode (on Disconnect or Dual Mode activation) restores local item & local routing!
      final localItem = audio_svc.MediaItem(
        id: 'android_local_7',
        title: 'Phone Local Track',
        artist: 'Mobile Artist',
        duration: const Duration(seconds: 180),
      );

      handler.exitRemoteMode(
        restoredLocalItem: localItem,
        localPlaying: false,
        localPosition: const Duration(seconds: 42),
        localDuration: const Duration(seconds: 180),
        localSpeed: 1.0,
      );

      expect(handler.isRemoteMode, isFalse);
      expect(handler.mediaItem.value?.id, 'android_local_7');
      expect(handler.mediaItem.value?.title, 'Phone Local Track');
      expect(handler.playbackState.value.playing, isFalse);

      // Now lockscreen controls route back to local Android player!
      await handler.play();
      await handler.skipToNext();
      expect(localPlayCalls, 1);
      expect(localNextCalls, 1);
      expect(remotePlayCalls, 1); // unchanged
    });
  });

  group('Cross-Device Discord RPC 3-Condition Failover Matrix', () {
    late ConnectPairedDevicesStore store;
    late ConnectShelfServer server;
    late int boundPort;
    late _FakeDiscordRpcService fakeRpc;

    final remoteTrack = MediaItem(
      id: 'rpc_track_1',
      path: 'https://music.youtube.com/watch?v=rpc_track_1',
      title: 'Cyberpunk Horizon',
      artist: 'Synthwave Runner',
      duration: const Duration(seconds: 190),
      type: 'audio',
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      store = ConnectPairedDevicesStore(prefs);
      fakeRpc = _FakeDiscordRpcService();

      // Start with Windows Discord RPC INACTIVE (e.g. Windows offline or Discord Desktop closed)
      final initialSync = ConnectPlaybackSync(
        currentTrack: remoteTrack,
        isPlaying: true,
        positionMs: 15000,
        durationMs: 190000,
        anchorTimestampMs: DateTime.now().millisecondsSinceEpoch,
        hostName: 'Windows-PC',
        isHostDiscordRpcActive: false,
      );

      server = ConnectShelfServer(
        store: store,
        onBuildInitialSync: () => ConnectPayload.sync(initialSync),
      );
      boundPort = await server.start(preferredPort: 52230);
    });

    tearDown(() async {
      await server.stop();
    });

    test(
        'Android takes over Discord RPC when Windows RPC is inactive, clears when Windows RPC activates, and yields to Android Local in Dual Mode',
        () async {
      final container = ProviderContainer(
        overrides: [
          connectPairedDevicesStoreProvider.overrideWithValue(store),
          discordRpcServiceProvider.overrideWithValue(fakeRpc),
          audioProvider.overrideWith(
            () => _FakeAudioNotifier(
              AudioState(
                currentTrack: MediaItem(
                  id: 'phone_song',
                  path: '/music/phone.mp3',
                  title: 'Phone Song',
                  artist: 'Phone Artist',
                  type: 'audio',
                ),
                isPlaying: false,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final hostDevice = ConnectDevice(
        id: store.localDeviceId,
        name: 'Windows-PC',
        ip: '127.0.0.1',
        port: boundPort,
        discoveryMethod: ConnectDiscoveryMethod.manualIp,
        lastSeen: DateTime.now(),
      );

      // 1. Connect while Windows isHostDiscordRpcActive == false -> Android takes over Discord RPC!
      final ok = await container
          .read(connectClientProvider.notifier)
          .connectToDevice(hostDevice, pin: store.pairingPin);
      expect(ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(fakeRpc.remoteSyncCalls, greaterThanOrEqualTo(1));
      expect(fakeRpc.lastSyncedRemoteTrack?.title, 'Cyberpunk Horizon');

      // 2. Windows Discord Desktop comes online (isHostDiscordRpcActive == true) -> Android clears its failover RPC!
      final hostActiveSync = ConnectPlaybackSync(
        currentTrack: remoteTrack,
        isPlaying: true,
        positionMs: 25000,
        durationMs: 190000,
        anchorTimestampMs: DateTime.now().millisecondsSinceEpoch,
        hostName: 'Windows-PC',
        isHostDiscordRpcActive: true,
      );
      server.broadcast(ConnectPayload.sync(hostActiveSync));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(fakeRpc.clearCalls, greaterThanOrEqualTo(1));

      await container.read(connectClientProvider.notifier).disconnectFromRemote();
    });
  });
}
