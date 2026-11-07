import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:resonance/core/configs/app_breakpoints.dart';
import 'package:resonance/core/data/services/storage_service.dart';
import 'package:resonance/core/domain/models/media_item.dart';
import 'package:resonance/core/providers/overlay_provider.dart';
import 'package:resonance/core/widgets/layout/sticky_sub_view_layout.dart';
import 'package:resonance/features/connect/application/connect_client_notifier.dart';
import 'package:resonance/features/connect/domain/models/connect_device.dart';
import 'package:resonance/features/connect/domain/models/connect_payload.dart';
import 'package:resonance/features/connect/domain/models/connect_playback_sync.dart';
import 'package:resonance/features/connect/infrastructure/server/connect_shelf_server.dart';
import 'package:resonance/features/connect/infrastructure/storage/connect_paired_devices_store.dart';
import 'package:resonance/features/connect/presentation/widgets/slideable_remote_mini_player.dart';
import 'package:resonance/features/player/application/providers/audio_provider.dart';

class _StubAudioNotifier extends AudioNotifier {
  @override
  AudioState build() => AudioState();

  @override
  Future<void> pause() async {}
}

void main() {
  group('SlideableRemoteMiniPlayer Widget & Gesture Tests', () {
    late SharedPreferences prefs;
    late ConnectPairedDevicesStore store;
    late ConnectShelfServer server;
    late int boundPort;
    final receivedCommands = <ConnectCommand>[];

    final remoteTrack = MediaItem(
      id: 'remote_track_42',
      path: '/music/starlight_symphony.flac',
      title: 'Starlight Symphony',
      artist: 'Nova Pulse',
      duration: const Duration(seconds: 200),
      type: 'audio',
    );

    setUp(() async {
      // Allow real loopback HTTP/WebSocket connections inside widget test
      HttpOverrides.global = null;
      receivedCommands.clear();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = ConnectPairedDevicesStore(prefs);

      final sync = ConnectPlaybackSync(
        currentTrack: remoteTrack,
        isPlaying: true,
        positionMs: 50000,
        durationMs: 200000,
        anchorTimestampMs: DateTime.now().millisecondsSinceEpoch,
        hostName: 'Gaming-PC',
        isHostDiscordRpcActive: true,
      );

      server = ConnectShelfServer(
        store: store,
        onBuildInitialSync: () => ConnectPayload.sync(sync),
      );
      boundPort = await server.start(preferredPort: 52240);
      server.commandStream.listen(receivedCommands.add);
    });

    tearDown(() async {
      await server.stop();
    });

    testWidgets(
        'renders only when Dual Mode is enabled, shrinks right & expands left, and routes tap to Remote NowPlaying',
        (tester) async {
      HttpOverrides.global = null;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          connectPairedDevicesStoreProvider.overrideWithValue(store),
          audioProvider.overrideWith(_StubAudioNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SlideableRemoteMiniPlayer(),
              ),
            ),
          ),
        ),
      );

      // 1. Hidden when disconnected
      expect(find.text('Starlight Symphony'), findsNothing);

      // 2. Connect to host using real loopback I/O, still hidden while Dual Mode is OFF
      final device = ConnectDevice(
        id: store.localDeviceId,
        name: 'Gaming-PC',
        ip: '127.0.0.1',
        port: boundPort,
        discoveryMethod: ConnectDiscoveryMethod.manualIp,
        lastSeen: DateTime.now(),
      );
      await tester.runAsync(() async {
        final ok = await container
            .read(connectClientProvider.notifier)
            .connectToDevice(device, pin: store.pairingPin);
        expect(ok, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();

      expect(container.read(isRemoteControlActiveProvider), isTrue);
      expect(container.read(isDualPlaybackEnabledProvider), isFalse);
      expect(find.text('Starlight Symphony'), findsNothing);

      // 3. Enable Dual Progress Bar Mode -> Bar appears with track title & host badge
      container.read(isDualPlaybackEnabledProvider.notifier).setEnabled(true);
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Starlight Symphony'), findsOneWidget);
      expect(find.text(store.localDeviceName), findsOneWidget);

      // 4. Tap "Next on Desktop" button on the secondary bar -> sends ConnectCommandAction.next
      await tester.tap(find.byTooltip('Next on Desktop'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      expect(
        receivedCommands.any((c) => c.action == ConnectCommandAction.next),
        isTrue,
      );

      // 5. Tap "Slide to edge" handle -> shrinks to right edge pill
      await tester.tap(find.byTooltip('Slide to edge'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // In shrunk pill mode, full title text is collapsed
      expect(find.text('Starlight Symphony'), findsNothing);
      expect(
        find.byKey(const ValueKey('slideable_remote_shrunk_pill')),
        findsOneWidget,
      );

      // 6. Tap the shrunk pill -> expands back to full width
      await tester.tap(find.byKey(const ValueKey('slideable_remote_shrunk_pill')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Starlight Symphony'), findsOneWidget);

      // 6b. Swipe right gesture -> shrinks to right edge pill; swipe left -> expands back
      await tester.drag(find.text('Starlight Symphony'), const Offset(120, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Starlight Symphony'), findsNothing);

      await tester.drag(
        find.byKey(const ValueKey('slideable_remote_shrunk_pill')),
        const Offset(-120, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Starlight Symphony'), findsOneWidget);

      // 7. Tap the expanded bar body -> sets dualOverlayTargetProvider to remote & opens NowPlaying
      container
          .read(dualOverlayTargetProvider.notifier)
          .setTarget(PlaybackTarget.local);
      expect(container.read(nowPlayingOverlayProvider), isFalse);

      await tester.tap(find.text('Starlight Symphony'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(container.read(dualOverlayTargetProvider), PlaybackTarget.remote);
      expect(container.read(isOverlayRemoteTargetProvider), isTrue);
      expect(container.read(nowPlayingOverlayProvider), isTrue);

      await tester.runAsync(() async {
        await container
            .read(connectClientProvider.notifier)
            .disconnectFromRemote();
      });
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets(
        'Tablet Wide Layout: StickySubViewLayout has zero top gap & transparent header, and mini players persist when NowPlaying opens on Tablet (>=600dp)',
        (tester) async {
      // Simulate Pixel Tablet landscape (1280x800 logical dp) with 24dp Android status bar padding
      tester.view.physicalSize = const Size(2560, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(1280, 800),
              padding: EdgeInsets.only(top: 24, bottom: 16),
            ),
            child: Builder(
              builder: (context) {
                final isWideLayout = AppBreakpoints.isWide(context);
                const isAndroid = true;
                const showNowPlaying = true;
                final showMiniPlayers =
                    !(isAndroid && !isWideLayout && showNowPlaying);

                return Scaffold(
                  body: Column(
                    children: [
                      Expanded(
                        child: SafeArea(
                          top: isWideLayout,
                          bottom: false,
                          child: MediaQuery.removePadding(
                            context: context,
                            removeTop: isWideLayout,
                            removeBottom: isWideLayout,
                            child: StickySubViewLayout(
                              title: 'Display Settings',
                              onBack: () {},
                              children: const [
                                Text('App & Appearance'),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (showMiniPlayers)
                        const SizedBox(
                          key: ValueKey('tablet_persistent_mini_player'),
                          height: 72,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      // 1. On 1280x800 tablet, mini player stays visible even when showNowPlaying == true
      expect(
        find.byKey(const ValueKey('tablet_persistent_mini_player')),
        findsOneWidget,
      );

      // 2. StickySubViewLayout header is flush with SafeArea top (y == 24.0) with no extra internal gap
      final headerTextTop = tester.getTopLeft(find.text('Display Settings')).dy;
      expect(headerTextTop, lessThan(50.0));
    });
  });
}
