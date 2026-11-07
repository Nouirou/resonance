import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/application/services/network_connectivity_service.dart';
import '../../../core/data/services/discord_rpc_service.dart';
import '../../../core/data/services/media_cache_service.dart';
import '../../../core/domain/models/media_item.dart';
import '../../player/application/audio_handler.dart';
import '../../player/application/providers/audio_provider.dart';
import '../domain/models/connect_payload.dart';
import '../domain/models/connect_playback_sync.dart';
import '../infrastructure/discovery/connect_mdns_discovery.dart';
import '../infrastructure/discovery/connect_udp_beacon.dart';
import '../infrastructure/server/connect_shelf_server.dart';
import '../infrastructure/storage/connect_paired_devices_store.dart';

class ConnectServerState {
  final bool isEnabled;
  final bool isRunning;
  final String localIp;
  final int port;
  final String hostId;
  final String hostName;
  final String pairingPin;
  final String qrSessionToken;
  final List<ConnectedClientSession> connectedClients;
  final List<TrustedClientRecord> trustedClients;
  final String? errorMessage;

  const ConnectServerState({
    this.isEnabled = false,
    this.isRunning = false,
    this.localIp = '127.0.0.1',
    this.port = ConnectShelfServer.defaultBasePort,
    this.hostId = '',
    this.hostName = 'Desktop PC',
    this.pairingPin = '0000',
    this.qrSessionToken = '',
    this.connectedClients = const [],
    this.trustedClients = const [],
    this.errorMessage,
  });

  String get endpoint => '$localIp:$port';

  String get qrConnectUri => Uri(
        scheme: 'resonance',
        host: 'connect',
        queryParameters: {
          'ip': localIp,
          'port': port.toString(),
          'token': qrSessionToken,
          'id': hostId,
          'name': hostName,
        },
      ).toString();

  ConnectServerState copyWith({
    bool? isEnabled,
    bool? isRunning,
    String? localIp,
    int? port,
    String? hostId,
    String? hostName,
    String? pairingPin,
    String? qrSessionToken,
    List<ConnectedClientSession>? connectedClients,
    List<TrustedClientRecord>? trustedClients,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ConnectServerState(
      isEnabled: isEnabled ?? this.isEnabled,
      isRunning: isRunning ?? this.isRunning,
      localIp: localIp ?? this.localIp,
      port: port ?? this.port,
      hostId: hostId ?? this.hostId,
      hostName: hostName ?? this.hostName,
      pairingPin: pairingPin ?? this.pairingPin,
      qrSessionToken: qrSessionToken ?? this.qrSessionToken,
      connectedClients: connectedClients ?? this.connectedClients,
      trustedClients: trustedClients ?? this.trustedClients,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

final connectServerProvider =
    NotifierProvider<ConnectServerNotifier, ConnectServerState>(
  ConnectServerNotifier.new,
);

class ConnectServerNotifier extends Notifier<ConnectServerState> {
  ConnectShelfServer? _shelfServer;
  final ConnectUdpBeacon _udpBeacon = ConnectUdpBeacon();
  final ConnectMdnsDiscovery _mdnsDiscovery = ConnectMdnsDiscovery();

  StreamSubscription? _commandSub;
  StreamSubscription? _sessionsSub;
  StreamSubscription<Duration>? _hardwarePosSub;
  Timer? _broadcastDebounceTimer;

  int _lastReportedPositionMs = 0;
  int _lastPositionCheckEpochMs = 0;

  @override
  ConnectServerState build() {
    final store = ref.watch(connectPairedDevicesStoreProvider);
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final enabled = store.isHostEnabled;

    ref.onDispose(() {
      _stopSubsystems();
    });

    _setupAudioStateListeners();

    if (enabled && isDesktop) {
      Future.microtask(() => startHostServer());
    }

    return ConnectServerState(
      isEnabled: enabled,
      isRunning: false,
      hostId: store.localDeviceId,
      hostName: store.localDeviceName,
      pairingPin: store.pairingPin,
      qrSessionToken: store.qrSessionToken,
      trustedClients: store.getTrustedClients(),
    );
  }

  void _setupAudioStateListeners() {
    ref.read(discordRpcServiceProvider).onPresenceStateChanged = () {
      if (_shelfServer?.isRunning == true &&
          (_shelfServer?.activeSessions.isNotEmpty ?? false)) {
        broadcastCurrentState();
      }
    };

    ref.listen(
      networkConnectivityProvider.select((s) => s.isOnline),
      (prev, next) {
        if (prev != next &&
            _shelfServer?.isRunning == true &&
            (_shelfServer?.activeSessions.isNotEmpty ?? false)) {
          broadcastCurrentState();
        }
      },
    );

    // Watch low-frequency state transitions on audioProvider (excluding high-frequency position)
    ref.listen(
      audioProvider.select(
        (s) => (
          s.currentTrack?.id ?? s.currentTrack?.path,
          s.isPlaying,
          s.isLoading,
          s.duration.inMilliseconds,
          s.volume,
          s.speed,
          s.pitch,
          s.loopMode,
          s.isShuffleEnabled,
          s.queue.length,
          s.currentIndex,
          s.currentTrack?.thumbnailUrl,
        ),
      ),
      (prev, next) {
        if (_shelfServer?.isRunning == true &&
            (_shelfServer?.activeSessions.isNotEmpty ?? false)) {
          // If only slider-dragged values (volume/speed/pitch) changed, debounce 45ms
          // to avoid serializing the entire queue at 60Hz.
          final onlySliderChanged = prev != null &&
              prev.$1 == next.$1 &&
              prev.$2 == next.$2 &&
              prev.$3 == next.$3 &&
              prev.$4 == next.$4 &&
              prev.$8 == next.$8 &&
              prev.$9 == next.$9 &&
              prev.$10 == next.$10 &&
              prev.$11 == next.$11 &&
              prev.$12 == next.$12 &&
              (prev.$5 != next.$5 || prev.$6 != next.$6 || prev.$7 != next.$7);
          if (onlySliderChanged) {
            _broadcastDebounceTimer?.cancel();
            _broadcastDebounceTimer = Timer(
              const Duration(milliseconds: 45),
              broadcastCurrentState,
            );
          } else {
            _broadcastDebounceTimer?.cancel();
            broadcastCurrentState();
          }
        }
      },
    );
  }

  /// Attaches the hardware position listener ONLY when at least 1 mobile remote is connected,
  /// and detaches it as soon as 0 remotes are connected (0% idle CPU overhead).
  void _syncHardwarePositionSubscription({required bool hasActiveClients}) {
    if (!hasActiveClients) {
      _hardwarePosSub?.cancel();
      _hardwarePosSub = null;
      _lastPositionCheckEpochMs = 0;
      return;
    }
    if (_hardwarePosSub != null) return;

    try {
      final audioHandler = ref.read(audioHandlerProvider);
      _hardwarePosSub = audioHandler.player.stream.position.listen((pos) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final posMs = pos.inMilliseconds;
        final elapsedRealMs = nowMs - _lastPositionCheckEpochMs;

        // Detect non-linear jump (seek) > 1500ms compared to expected linear progress
        if (_lastPositionCheckEpochMs > 0 && elapsedRealMs > 0) {
          final isPlaying = ref.read(audioProvider).isPlaying;
          final expectedDeltaMs = isPlaying ? elapsedRealMs : 0;
          final actualDeltaMs = posMs - _lastReportedPositionMs;
          if ((actualDeltaMs - expectedDeltaMs).abs() > 1500) {
            _lastReportedPositionMs = posMs;
            _lastPositionCheckEpochMs = nowMs;
            if (_shelfServer?.isRunning == true &&
                (_shelfServer?.activeSessions.isNotEmpty ?? false)) {
              broadcastCurrentState(overridePosition: pos);
            }
            return;
          }
        }

        _lastReportedPositionMs = posMs;
        _lastPositionCheckEpochMs = nowMs;
      });
    } catch (_) {}
  }

  Future<void> setHostEnabled(bool enabled) async {
    final store = ref.read(connectPairedDevicesStoreProvider);
    await store.setHostEnabled(enabled);
    state = state.copyWith(isEnabled: enabled, clearError: true);
    if (enabled) {
      await startHostServer();
    } else {
      await stopHostServer();
    }
  }

  Future<void> startHostServer() async {
    if (_shelfServer?.isRunning == true) {
      await refreshNetworkAddress();
      return;
    }

    final store = ref.read(connectPairedDevicesStoreProvider);
    try {
      final localIp = await ConnectUdpBeacon.resolvePrimaryLanIp();
      final server = ConnectShelfServer(
        store: store,
        onResolveArtwork: _resolveTrackArtworkBytes,
        onBuildInitialSync: () => ConnectPayload.sync(_buildPlaybackSync()),
        onClientUnpaired: (_) async {
          state = state.copyWith(
            trustedClients: store.getTrustedClients(),
          );
        },
      );

      final boundPort = await server.start();
      _shelfServer = server;

      _commandSub?.cancel();
      _commandSub = server.commandStream.listen(_executeRemoteCommand);

      _sessionsSub?.cancel();
      _sessionsSub = server.sessionsStream.listen((sessions) {
        _syncHardwarePositionSubscription(
          hasActiveClients: sessions.isNotEmpty,
        );
        state = state.copyWith(
          connectedClients: sessions,
          trustedClients: store.getTrustedClients(),
        );
      });

      await _udpBeacon.startHostResponder(
        hostId: store.localDeviceId,
        hostName: store.localDeviceName,
        wsPort: boundPort,
      );

      await _mdnsDiscovery.startAdvertising(
        hostId: store.localDeviceId,
        hostName: store.localDeviceName,
        port: boundPort,
      );

      state = state.copyWith(
        isRunning: true,
        localIp: localIp,
        port: boundPort,
        hostId: store.localDeviceId,
        hostName: store.localDeviceName,
        pairingPin: store.pairingPin,
        qrSessionToken: store.qrSessionToken,
        trustedClients: store.getTrustedClients(),
        clearError: true,
      );
    } catch (e) {
      debugPrint('[Connect] Failed starting host server: $e');
      state = state.copyWith(
        isRunning: false,
        errorMessage: 'Failed to start Connect server: $e',
      );
    }
  }

  Future<void> stopHostServer() async {
    await _stopSubsystems();
    state = state.copyWith(
      isRunning: false,
      connectedClients: const [],
    );
  }

  Future<void> _stopSubsystems() async {
    _broadcastDebounceTimer?.cancel();
    _broadcastDebounceTimer = null;
    await _commandSub?.cancel();
    _commandSub = null;
    await _sessionsSub?.cancel();
    _sessionsSub = null;
    await _hardwarePosSub?.cancel();
    _hardwarePosSub = null;
    await _udpBeacon.stopHostResponder();
    await _mdnsDiscovery.stopAdvertising();
    final srv = _shelfServer;
    _shelfServer = null;
    if (srv != null) {
      await srv.dispose();
    }
  }

  Future<void> refreshNetworkAddress() async {
    final ip = await ConnectUdpBeacon.resolvePrimaryLanIp();
    state = state.copyWith(localIp: ip);
  }

  void regeneratePinAndQrToken() {
    final store = ref.read(connectPairedDevicesStoreProvider);
    final newPin = store.regeneratePairingPin();
    final newQr = store.regenerateQrSessionToken();
    state = state.copyWith(
      pairingPin: newPin,
      qrSessionToken: newQr,
    );
  }

  Future<void> revokeClient(String clientId) async {
    final store = ref.read(connectPairedDevicesStoreProvider);
    await store.revokeTrustedClient(clientId);
    await _shelfServer?.disconnectClient(clientId);
    state = state.copyWith(
      trustedClients: store.getTrustedClients(),
    );
  }

  void broadcastCurrentState({Duration? overridePosition}) {
    final srv = _shelfServer;
    if (srv == null || !srv.isRunning) return;
    final sync = _buildPlaybackSync(overridePosition: overridePosition);
    srv.broadcast(ConnectPayload.sync(sync));
  }

  ConnectPlaybackSync _buildPlaybackSync({Duration? overridePosition}) {
    final audioState = ref.read(audioProvider);
    final store = ref.read(connectPairedDevicesStoreProvider);

    // Read real hardware position from player so tray-minimized desktop isn't frozen
    Duration effectivePosition = overridePosition ?? audioState.position;
    try {
      final hardwarePos = ref.read(audioHandlerProvider).player.state.position;
      if (overridePosition == null && hardwarePos > Duration.zero) {
        effectivePosition = hardwarePos;
      }
    } catch (_) {}

    final currentTrack = _rewriteLocalArtworkUrl(audioState.currentTrack);
    final nextTrack = _rewriteLocalArtworkUrl(audioState.nextTrack);
    final rewrittenQueue =
        audioState.queue.map((t) => _rewriteLocalArtworkUrl(t)!).toList();

    final effectiveDuration = audioState.duration > Duration.zero
        ? audioState.duration
        : (currentTrack?.duration ?? Duration.zero);

    final isHostRpcActive =
        ref.read(discordRpcServiceProvider).isPresenceActive;

    return ConnectPlaybackSync(
      currentTrack: currentTrack,
      isPlaying: audioState.isPlaying,
      isLoading: audioState.isLoading,
      positionMs: effectivePosition.inMilliseconds,
      durationMs: effectiveDuration.inMilliseconds,
      anchorTimestampMs: DateTime.now().millisecondsSinceEpoch,
      playbackRate: audioState.speed,
      pitch: audioState.pitch,
      volume: audioState.volume,
      loopMode: audioState.loopMode,
      isShuffleEnabled: audioState.isShuffleEnabled,
      queue: rewrittenQueue,
      currentIndex: audioState.currentIndex,
      nextTrack: nextTrack,
      hostName: store.localDeviceName,
      isHostDiscordRpcActive: isHostRpcActive,
    );
  }

  /// Rewrites local track artwork URLs to point to the Desktop Shelf `/art/<id>` endpoint
  /// so mobile clients can render embedded ID3 album art or Windows disk-cached art over LAN,
  /// and strips raw `Uint8List` buffers from the sync snapshot to prevent memory duplication.
  MediaItem? _rewriteLocalArtworkUrl(MediaItem? item) {
    if (item == null) return null;
    final hasRemoteThumb = item.thumbnailUrl != null &&
        item.thumbnailUrl!.isNotEmpty &&
        item.thumbnailUrl!.startsWith('http');
    if (hasRemoteThumb) {
      return item.albumArt != null ? item.copyWith(clearAlbumArt: true) : item;
    }

    final trackKey = item.id ?? item.path;
    if (trackKey.isNotEmpty &&
        (item.isLocal ||
            (item.albumArt != null && item.albumArt!.isNotEmpty) ||
            (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty))) {
      final artUrl =
          'http://${state.localIp}:${state.port}/art/${Uri.encodeComponent(trackKey)}';
      return item.copyWith(
        thumbnailUrl: artUrl,
        clearAlbumArt: true,
      );
    }
    return item;
  }

  Future<Uint8List?> _resolveTrackArtworkBytes(String trackKey) async {
    final audioState = ref.read(audioProvider);
    final current = audioState.currentTrack;
    MediaItem? matchedItem;
    if (current != null &&
        (current.id == trackKey || current.path == trackKey)) {
      if (current.albumArt != null && current.albumArt!.isNotEmpty) {
        return current.albumArt;
      }
      matchedItem = current;
    }
    for (final t in audioState.queue) {
      if (t.id == trackKey || t.path == trackKey) {
        if (t.albumArt != null && t.albumArt!.isNotEmpty) {
          return t.albumArt;
        }
        matchedItem ??= t;
      }
    }

    // Fallback 1: Check if thumbnailUrl on matched item points to a local file on Windows disk
    if (matchedItem?.thumbnailUrl != null &&
        matchedItem!.thumbnailUrl!.isNotEmpty &&
        !matchedItem.thumbnailUrl!.startsWith('http')) {
      try {
        final file = File(matchedItem.thumbnailUrl!);
        if (await file.exists()) {
          return await file.readAsBytes();
        }
      } catch (_) {}
    }

    // Fallback 2: Check Windows MediaCacheService disk artwork cache by songId
    try {
      final cachedPath =
          await ref.read(mediaCacheServiceProvider).getCachedArtPath(trackKey);
      if (cachedPath != null && cachedPath.isNotEmpty) {
        final file = File(cachedPath);
        if (await file.exists()) {
          return await file.readAsBytes();
        }
      }
    } catch (_) {}

    return null;
  }

  void _executeRemoteCommand(ConnectCommand cmd) {
    final notifier = ref.read(audioProvider.notifier);
    switch (cmd.action) {
      case ConnectCommandAction.play:
        notifier.play();
        break;
      case ConnectCommandAction.pause:
        notifier.pause();
        break;
      case ConnectCommandAction.togglePlayPause:
        notifier.togglePlayPause();
        break;
      case ConnectCommandAction.seek:
        if (cmd.positionMs != null) {
          final target = Duration(milliseconds: cmd.positionMs!);
          notifier.seek(target);
          broadcastCurrentState(overridePosition: target);
        }
        break;
      case ConnectCommandAction.next:
        notifier.skipToNext();
        break;
      case ConnectCommandAction.previous:
        notifier.skipToPrevious();
        break;
      case ConnectCommandAction.setVolume:
        if (cmd.volume != null) {
          notifier.setVolume(cmd.volume!.clamp(0.0, 100.0));
        }
        break;
      case ConnectCommandAction.setSpeed:
        if (cmd.speed != null) {
          notifier.setSpeed(cmd.speed!.clamp(0.25, 2.0));
        }
        break;
      case ConnectCommandAction.setPitch:
        if (cmd.pitch != null) {
          notifier.setPitch(cmd.pitch!.clamp(-12.0, 12.0));
        }
        break;
      case ConnectCommandAction.toggleShuffle:
        notifier.toggleShuffle();
        break;
      case ConnectCommandAction.cycleLoopMode:
        notifier.cycleLoopMode();
        break;
      case ConnectCommandAction.jumpToQueueIndex:
        if (cmd.index != null) {
          notifier.jumpToQueueIndex(cmd.index!);
        }
        break;
      case ConnectCommandAction.removeTrackFromQueue:
        if (cmd.index != null) {
          notifier.removeTrackFromQueue(cmd.index!);
        }
        break;
      case ConnectCommandAction.reorderQueue:
        if (cmd.oldIndex != null && cmd.newIndex != null) {
          notifier.reorderQueue(cmd.oldIndex!, cmd.newIndex!);
        }
        break;
      case ConnectCommandAction.clearUpcomingQueue:
        notifier.clearUpcomingQueue();
        break;
      case ConnectCommandAction.playTrack:
        if (cmd.track != null) {
          if (cmd.track!.isStreaming) {
            notifier.playYouTubeTrack(cmd.track!);
          } else {
            notifier.playTrack(cmd.track!);
          }
        }
        break;
      case ConnectCommandAction.addToQueue:
        if (cmd.track != null) {
          notifier.addToQueue(cmd.track!);
        }
        break;
      case ConnectCommandAction.playNext:
        if (cmd.track != null) {
          notifier.playNext(cmd.track!);
        }
        break;
      case ConnectCommandAction.requestSync:
        broadcastCurrentState();
        break;
    }
  }
}

