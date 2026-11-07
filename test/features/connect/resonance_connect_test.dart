import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/core/domain/models/media_item.dart';
import 'package:resonance/features/connect/domain/models/connect_device.dart';
import 'package:resonance/features/connect/domain/models/connect_payload.dart';
import 'package:resonance/features/connect/domain/models/connect_playback_sync.dart';
import 'package:resonance/features/connect/infrastructure/client/connect_socket_client.dart';
import 'package:resonance/features/connect/infrastructure/server/connect_shelf_server.dart';
import 'package:resonance/features/connect/infrastructure/storage/connect_paired_devices_store.dart';
import 'package:resonance/features/player/data/models/player_enums.dart';

void main() {
  group('ConnectPlaybackSync Clock-Anchor & Serialization', () {
    test('interpolates playback position accurately using anchorTimestampMs', () {
      const anchor = 1000000;
      const sync = ConnectPlaybackSync(
        isPlaying: true,
        isLoading: false,
        positionMs: 10000, // 10s
        durationMs: 60000, // 60s
        anchorTimestampMs: anchor,
        playbackRate: 1.0,
        volume: 85.0,
      );

      // 2.5 seconds after anchor -> 12.5s
      final posAfter2500ms = sync.computePositionAt(nowMs: anchor + 2500);
      expect(posAfter2500ms.inMilliseconds, 12500);

      // Clamps at durationMs (60s)
      final posBeyondEnd = sync.computePositionAt(nowMs: anchor + 90000);
      expect(posBeyondEnd.inMilliseconds, 60000);

      // When paused, returns exact positionMs regardless of elapsed time
      const pausedSync = ConnectPlaybackSync(
        isPlaying: false,
        positionMs: 10000,
        durationMs: 60000,
        anchorTimestampMs: anchor,
      );
      expect(
        pausedSync.computePositionAt(nowMs: anchor + 5000).inMilliseconds,
        10000,
      );
    });

    test('roundtrips ConnectPlaybackSync and ConnectPayload through JSON', () {
      final track = MediaItem(
        id: 'yt_123',
        path: 'https://music.youtube.com/watch?v=yt_123',
        title: 'Resonance Test Song',
        artist: 'Chrono Studio',
        album: 'LAN Sessions',
        duration: const Duration(seconds: 210),
        type: 'audio',
      );

      final sync = ConnectPlaybackSync(
        currentTrack: track,
        isPlaying: true,
        isLoading: false,
        positionMs: 42000,
        durationMs: 210000,
        anchorTimestampMs: 1700000000000,
        playbackRate: 1.25,
        pitch: -2.0,
        volume: 75.0,
        loopMode: LoopMode.all,
        isShuffleEnabled: true,
        queue: [track],
        currentIndex: 0,
        nextTrack: track,
        hostName: 'Studio-PC',
        isHostDiscordRpcActive: true,
      );

      final rawJson = ConnectPayload.sync(sync).encode();
      final decoded = ConnectPayload.tryDecode(rawJson);

      expect(decoded, isNotNull);
      expect(decoded!.type, ConnectPayloadType.playbackSync);
      expect(decoded.sync, isNotNull);
      expect(decoded.sync!.currentTrack?.title, 'Resonance Test Song');
      expect(decoded.sync!.positionMs, 42000);
      expect(decoded.sync!.playbackRate, 1.25);
      expect(decoded.sync!.pitch, -2.0);
      expect(decoded.sync!.volume, 75.0);
      expect(decoded.sync!.loopMode, LoopMode.all);
      expect(decoded.sync!.isShuffleEnabled, isTrue);
      expect(decoded.sync!.hostName, 'Studio-PC');
      expect(decoded.sync!.isHostDiscordRpcActive, isTrue);

      final speedCmdJson = ConnectPayload.command(
        const ConnectCommand(
          action: ConnectCommandAction.setSpeed,
          speed: 1.5,
          pitch: 3.0,
        ),
      ).encode();
      final decodedCmd = ConnectPayload.tryDecode(speedCmdJson);
      expect(decodedCmd?.command?.action, ConnectCommandAction.setSpeed);
      expect(decodedCmd?.command?.speed, 1.5);
      expect(decodedCmd?.command?.pitch, 3.0);
    });
  });

  group('ConnectShelfServer & ConnectSocketClient E2E LAN Protocol', () {
    late ConnectPairedDevicesStore store;
    late ConnectShelfServer server;
    late ConnectSocketClient client;
    late int boundPort;

    final currentHostSync = ConnectPlaybackSync(
      currentTrack: MediaItem(
        id: 'track_1',
        path: '/music/song.flac',
        title: 'Local FLAC Track',
        artist: 'Test Artist',
        duration: const Duration(seconds: 180),
        type: 'audio',
      ),
      isPlaying: true,
      positionMs: 5000,
      durationMs: 180000,
      anchorTimestampMs: 1700000000000,
      volume: 90.0,
      hostName: 'Test-Desktop',
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      store = ConnectPairedDevicesStore(prefs);

      server = ConnectShelfServer(
        store: store,
        onBuildInitialSync: () => ConnectPayload.sync(currentHostSync),
        onResolveArtwork: (id) async =>
            id == 'track_1' ? Uint8List.fromList([1, 2, 3, 4]) : null,
      );
      boundPort = await server.start(preferredPort: 52126);
      client = ConnectSocketClient();
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('probes /info, pairs with 4-digit PIN, syncs state & dispatches commands',
        () async {
      expect(server.isRunning, isTrue);

      // 1. Probe /info
      final discovered = await ConnectSocketClient.probeHost(
        ip: '127.0.0.1',
        port: boundPort,
        method: ConnectDiscoveryMethod.manualIp,
      );
      expect(discovered, isNotNull);
      expect(discovered!.id, store.localDeviceId);

      // 2. Reject invalid PIN
      expect(
        () => ConnectSocketClient.pairWithHost(
          device: discovered,
          clientId: 'phone_1',
          clientName: 'Pixel 9',
          pin: '99999', // Invalid length/PIN
        ),
        throwsException,
      );

      // 3. Pair with valid 4-digit PIN
      final pairedDevice = await ConnectSocketClient.pairWithHost(
        device: discovered,
        clientId: 'phone_1',
        clientName: 'Pixel 9',
        pin: store.pairingPin,
      );
      expect(pairedDevice.isPaired, isTrue);
      expect(pairedDevice.authToken, isNotNull);
      expect(pairedDevice.authToken, isNotEmpty);

      // 4. Connect WebSocket & receive initial playbackSync
      final firstSyncFuture = client.payloadStream
          .firstWhere((p) => p.type == ConnectPayloadType.playbackSync);

      await client.connect(
        device: pairedDevice,
        authToken: pairedDevice.authToken!,
        clientId: 'phone_1',
        clientName: 'Pixel 9',
      );

      final initialPayload =
          await firstSyncFuture.timeout(const Duration(seconds: 3));
      expect(
        initialPayload.sync?.currentTrack?.title,
        'Local FLAC Track',
      );
      expect(initialPayload.sync?.volume, 90.0);

      // 5. Send remote command (seek to 30s) from mobile client to desktop server
      final commandFuture = server.commandStream.first;
      client.sendCommand(
        const ConnectCommand(
          action: ConnectCommandAction.seek,
          positionMs: 30000,
        ),
      );

      final receivedCmd =
          await commandFuture.timeout(const Duration(seconds: 3));
      expect(receivedCmd.action, ConnectCommandAction.seek);
      expect(receivedCmd.positionMs, 30000);

      // 6. Verify /info validates token while paired, and invalidates after host revokes client
      final probeValid = await ConnectSocketClient.probeHost(
        ip: '127.0.0.1',
        port: boundPort,
        savedAuthToken: pairedDevice.authToken,
      );
      expect(probeValid?.isPaired, isTrue);

      final disconnectFuture = client.payloadStream.firstWhere(
        (p) => p.type == ConnectPayloadType.disconnect,
      );
      await store.revokeTrustedClient('phone_1');
      await server.disconnectClient('phone_1', reason: 'revoked');

      final disconnectPayload =
          await disconnectFuture.timeout(const Duration(seconds: 3));
      expect(disconnectPayload.message, 'revoked');

      final probeAfterRevoke = await ConnectSocketClient.probeHost(
        ip: '127.0.0.1',
        port: boundPort,
        savedAuthToken: pairedDevice.authToken,
      );
      expect(probeAfterRevoke?.isPaired, isFalse);
      expect(probeAfterRevoke?.authToken, isNull);
    });
  });
}
