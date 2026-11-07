import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart' as audio_svc;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/services/discord_rpc_service.dart';
import '../../../core/domain/models/media_item.dart';
import '../../player/application/audio_handler.dart';
import '../../player/application/providers/audio_provider.dart';
import '../../settings/application/notification_provider.dart';
import '../domain/errors/connect_exception.dart';
import '../domain/models/connect_device.dart';
import '../domain/models/connect_payload.dart';
import '../domain/models/connect_playback_sync.dart';
import '../domain/models/connect_status.dart';
import '../infrastructure/client/connect_socket_client.dart';
import '../infrastructure/storage/connect_paired_devices_store.dart';
import 'connect_discovery_notifier.dart';

/// Identifies which playback engine an overlay (NowPlayingScreen, QueueScreen,
/// LyricsScreen, AudioSettingsSheet) is inspecting when Dual Mode is active.
enum PlaybackTarget {
  local,
  remote,
}

class DualPlaybackModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setEnabled(bool enabled) {
    if (state == enabled) return;
    state = enabled;
    ref
        .read(dualOverlayTargetProvider.notifier)
        .setTarget(enabled ? PlaybackTarget.local : PlaybackTarget.remote);
    ref.read(connectClientProvider.notifier).onDualModeChanged(enabled);
  }

  void toggle() => setEnabled(!state);

  void resetOnDisconnect() {
    if (state) {
      state = false;
    }
    ref.read(dualOverlayTargetProvider.notifier).setTarget(PlaybackTarget.local);
  }
}

/// Whether the user has activated the Slideable Dual Bottom Progress Bar
/// to play local music on Android while staying connected to Desktop.
final isDualPlaybackEnabledProvider =
    NotifierProvider<DualPlaybackModeNotifier, bool>(
  DualPlaybackModeNotifier.new,
);

class DualOverlayTargetNotifier extends Notifier<PlaybackTarget> {
  @override
  PlaybackTarget build() => PlaybackTarget.local;

  void setTarget(PlaybackTarget target) {
    if (state != target) {
      state = target;
    }
  }
}

/// Tracks which bottom bar was clicked to open NowPlayingScreen / QueueScreen / LyricsScreen
/// when Dual Progress Bar Mode is active.
final dualOverlayTargetProvider =
    NotifierProvider<DualOverlayTargetNotifier, PlaybackTarget>(
  DualOverlayTargetNotifier.new,
);

class ConnectClientState {
  final ConnectStatus status;
  final ConnectDevice? activeDevice;
  final ConnectPlaybackSync? remoteSync;
  final Duration interpolatedPosition;
  final String? errorMessage;

  const ConnectClientState({
    this.status = ConnectStatus.disconnected,
    this.activeDevice,
    this.remoteSync,
    this.interpolatedPosition = Duration.zero,
    this.errorMessage,
  });

  bool get isActiveRemote =>
      status == ConnectStatus.activeRemote && activeDevice != null;

  bool get isConnecting => status == ConnectStatus.connecting;

  ConnectClientState copyWith({
    ConnectStatus? status,
    ConnectDevice? activeDevice,
    bool clearActiveDevice = false,
    ConnectPlaybackSync? remoteSync,
    bool clearRemoteSync = false,
    Duration? interpolatedPosition,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ConnectClientState(
      status: status ?? this.status,
      activeDevice:
          clearActiveDevice ? null : (activeDevice ?? this.activeDevice),
      remoteSync: clearRemoteSync ? null : (remoteSync ?? this.remoteSync),
      interpolatedPosition: interpolatedPosition ?? this.interpolatedPosition,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

final connectClientProvider =
    NotifierProvider<ConnectClientNotifier, ConnectClientState>(
  ConnectClientNotifier.new,
);

/// True whenever the WebSocket remote connection to a Desktop Host is alive.
final isRemoteControlActiveProvider = Provider<bool>((ref) {
  return ref.watch(connectClientProvider.select((s) => s.isActiveRemote));
});

/// True ONLY in Single Remote Mode (`isRemoteControlActive && !isDualPlaybackEnabled`).
/// Consumed by the lower `DockedMiniPlayer`, `ResonanceAudioHandler` (OS Notification),
/// and default quick actions. When Dual Mode is enabled, this is `false` so the lower bar
/// and OS notification focus 100% on Android Local playback.
final isDockedBarRemoteProvider = Provider<bool>((ref) {
  final isRemote = ref.watch(isRemoteControlActiveProvider);
  final isDual = ref.watch(isDualPlaybackEnabledProvider);
  return isRemote && !isDual;
});

/// Determines whether full-screen overlays (`NowPlayingScreen`, `QueueScreen`,
/// `LyricsScreen`, `LyricsNotifier`, `AudioSettingsSheet`) should display and control
/// the remote Desktop Host (`true`) or local Android player (`false`).
final isOverlayRemoteTargetProvider = Provider<bool>((ref) {
  final isRemote = ref.watch(isRemoteControlActiveProvider);
  if (!isRemote) return false;
  final isDual = ref.watch(isDualPlaybackEnabledProvider);
  if (!isDual) return true;
  final target = ref.watch(dualOverlayTargetProvider);
  return target == PlaybackTarget.remote;
});

class ConnectClientNotifier extends Notifier<ConnectClientState> {
  final ConnectSocketClient _socketClient = ConnectSocketClient();
  StreamSubscription? _payloadSub;
  StreamSubscription? _connStateSub;
  Timer? _clockInterpolationTimer;
  Timer? _discordRecoveryTimer;
  Timer? _reconnectTimer;
  Timer? _volumeSendDebounceTimer;
  Timer? _speedSendDebounceTimer;
  Timer? _pitchSendDebounceTimer;
  int _reconnectAttempts = 0;
  bool _manualDisconnect = false;
  bool _isPublishingRemoteDiscordRpc = false;

  @override
  ConnectClientState build() {
    ref.onDispose(() {
      _clockInterpolationTimer?.cancel();
      _discordRecoveryTimer?.cancel();
      _reconnectTimer?.cancel();
      _volumeSendDebounceTimer?.cancel();
      _speedSendDebounceTimer?.cancel();
      _pitchSendDebounceTimer?.cancel();
      _payloadSub?.cancel();
      _connStateSub?.cancel();
      _socketClient.dispose();
    });

    _payloadSub = _socketClient.payloadStream.listen(_onPayloadReceived);
    _connStateSub =
        _socketClient.connectionStateStream.listen(_onSocketStateChanged);

    return const ConnectClientState();
  }

  /// Connects to [device]. If not yet paired (or missing `authToken`), uses [pin] or [qrToken]
  /// to pair via `POST /pair`, persists the token, and opens the WebSocket channel.
  Future<bool> connectToDevice(
    ConnectDevice device, {
    String? pin,
    String? qrToken,
  }) async {
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    final store = ref.read(connectPairedDevicesStoreProvider);
    ConnectDevice targetDevice = device;

    // Check if we already have a stored token for this device
    if ((targetDevice.authToken == null || targetDevice.authToken!.isEmpty) &&
        pin == null &&
        qrToken == null) {
      final saved = store.getPairedHostById(targetDevice.id);
      if (saved?.authToken != null && saved!.authToken!.isNotEmpty) {
        targetDevice = targetDevice.copyWith(
          isPaired: true,
          authToken: saved.authToken,
        );
      }
    }

    if ((targetDevice.authToken == null || targetDevice.authToken!.isEmpty) &&
        pin == null &&
        qrToken == null) {
      state = state.copyWith(
        status: ConnectStatus.pairingRequired,
        activeDevice: targetDevice,
        clearError: true,
      );
      return false;
    }

    state = state.copyWith(
      status: ConnectStatus.connecting,
      activeDevice: targetDevice,
      clearError: true,
    );

    try {
      // Perform HTTP pairing if PIN or QR token provided or if no authToken exists
      if (pin != null ||
          qrToken != null ||
          targetDevice.authToken == null ||
          targetDevice.authToken!.isEmpty) {
        targetDevice = await ConnectSocketClient.pairWithHost(
          device: targetDevice,
          pin: pin,
          qrToken: qrToken,
          clientId: store.localDeviceId,
          clientName: store.localDeviceName,
        );
        await store.savePairedHost(targetDevice);
        ref
            .read(connectDiscoveryProvider.notifier)
            .upsertPairedDevice(targetDevice);
      }

      await _socketClient.connect(
        device: targetDevice,
        authToken: targetDevice.authToken!,
        clientId: store.localDeviceId,
        clientName: store.localDeviceName,
      );

      // Pause local player when switching into Single Remote Controller mode
      // (without clearing local currentTrack or queue so they restore on disconnect!)
      try {
        final isDual = ref.read(isDualPlaybackEnabledProvider);
        final localAudio = ref.read(audioProvider);
        if (!isDual && localAudio.isPlaying) {
          ref.read(audioProvider.notifier).pause();
        }
      } catch (_) {}

      state = state.copyWith(
        status: ConnectStatus.activeRemote,
        activeDevice: targetDevice,
        clearError: true,
      );

      _syncInterpolationTicker();
      _syncDiscordRecoveryWatchdog();

      ref.read(notificationProvider.notifier).showNotification(
            'Resonance Connect',
            'Connected to ${targetDevice.name}.',
            silentOsNotification: true,
          );
      return true;
    } on ConnectException catch (e) {
      if (e.code == 'INVALID_PIN') {
        state = state.copyWith(
          status: ConnectStatus.pairingRequired,
          activeDevice: targetDevice,
          errorMessage: e.message,
        );
      } else {
        state = state.copyWith(
          status: ConnectStatus.error,
          errorMessage: e.message,
        );
      }
      return false;
    } catch (e) {
      // If stored token was revoked on desktop, wipe stale token and prompt for re-pairing
      await store.removePairedHost(targetDevice.id);
      await ref
          .read(connectDiscoveryProvider.notifier)
          .markDeviceUnpaired(targetDevice.id);
      state = state.copyWith(
        status: ConnectStatus.pairingRequired,
        activeDevice: targetDevice.copyWith(
          isPaired: false,
          clearAuthToken: true,
        ),
        errorMessage:
            'Authentication expired or revoked on Desktop. Enter the 4-digit PIN to pair again.',
      );
      return false;
    }
  }

  /// Parses a `resonance://connect?ip=...&port=...&token=...` QR code URI and connects immediately.
  Future<bool> connectViaQrUri(String rawUri) async {
    final uri = Uri.tryParse(rawUri.trim());
    if (uri == null ||
        (uri.scheme != 'resonance' && uri.scheme != 'res') ||
        uri.host != 'connect') {
      state = state.copyWith(
        status: ConnectStatus.error,
        errorMessage: 'Invalid Resonance Connect QR code.',
      );
      return false;
    }

    final ip = uri.queryParameters['ip']?.trim() ?? '';
    final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? 52026;
    final qrToken = uri.queryParameters['token']?.trim() ?? '';
    final hostId = uri.queryParameters['id']?.trim() ?? 'host_$ip';
    final hostName = uri.queryParameters['name']?.trim() ?? 'Desktop PC';

    if (ip.isEmpty || qrToken.isEmpty) {
      state = state.copyWith(
        status: ConnectStatus.error,
        errorMessage: 'Incomplete QR code payload.',
      );
      return false;
    }

    final device = ConnectDevice(
      id: hostId,
      name: hostName,
      ip: ip,
      port: port,
      discoveryMethod: ConnectDiscoveryMethod.qrCode,
      lastSeen: DateTime.now(),
    );

    return connectToDevice(device, qrToken: qrToken);
  }

  /// Connects via manual IP (e.g. `192.168.1.15` or `192.168.1.15:52026`) and 4-digit PIN.
  Future<bool> connectViaManualIp({
    required String hostAddress,
    required String pin,
  }) async {
    final cleaned = hostAddress.trim();
    if (cleaned.isEmpty) {
      state = state.copyWith(
        status: ConnectStatus.error,
        errorMessage: 'Enter a valid IP address.',
      );
      return false;
    }

    String ip = cleaned;
    int port = 52026;
    if (cleaned.contains(':')) {
      final parts = cleaned.split(':');
      ip = parts.first.trim();
      port = int.tryParse(parts.last.trim()) ?? 52026;
    }

    state = state.copyWith(
      status: ConnectStatus.connecting,
      clearError: true,
    );

    final probed = await ConnectSocketClient.probeHost(ip: ip, port: port);
    final device = probed ??
        ConnectDevice(
          id: 'manual_$ip',
          name: 'Desktop ($ip)',
          ip: ip,
          port: port,
          discoveryMethod: ConnectDiscoveryMethod.manualIp,
          lastSeen: DateTime.now(),
        );

    return connectToDevice(device, pin: pin);
  }

  /// Called when the user toggles Dual Bottom Progress Bar Mode in `ConnectDevicesSheet`.
  void onDualModeChanged(bool isDualEnabled) {
    if (!state.isActiveRemote) return;
    if (isDualEnabled) {
      // Immediately detach Android OS Notification from remote and restore local Android state
      _restoreLocalNotificationAndDiscordState();
    } else {
      // Re-attach Android OS Notification to remote Windows track
      final localAudio = ref.read(audioProvider);
      if (localAudio.isPlaying) {
        ref.read(audioProvider.notifier).pause();
      }
      final sync = state.remoteSync;
      if (sync != null) {
        _syncRemoteNotificationState(sync, state.interpolatedPosition);
        _syncRemoteDiscordFailover(sync, state.interpolatedPosition);
      }
    }
  }

  Future<void> disconnectFromRemote() async {
    _manualDisconnect = true;
    _cleanupTimers();
    await _socketClient.disconnect();
    _restoreLocalNotificationAndDiscordState();
    ref.read(isDualPlaybackEnabledProvider.notifier).resetOnDisconnect();
    state = const ConnectClientState(status: ConnectStatus.disconnected);
  }

  void _cleanupTimers() {
    _reconnectTimer?.cancel();
    _volumeSendDebounceTimer?.cancel();
    _speedSendDebounceTimer?.cancel();
    _pitchSendDebounceTimer?.cancel();
    _clockInterpolationTimer?.cancel();
    _clockInterpolationTimer = null;
    _discordRecoveryTimer?.cancel();
    _discordRecoveryTimer = null;
  }

  void _onPayloadReceived(ConnectPayload payload) {
    if (payload.type == ConnectPayloadType.playbackSync &&
        payload.sync != null) {
      final sync = payload.sync!;
      final pos = sync.computePositionAt();
      state = state.copyWith(
        status: ConnectStatus.activeRemote,
        remoteSync: sync,
        interpolatedPosition: pos,
        clearError: true,
      );
      _syncInterpolationTicker();
      _syncDiscordRecoveryWatchdog();
      _syncRemoteNotificationState(sync, pos);
      _syncRemoteDiscordFailover(sync, pos);
    } else if (payload.type == ConnectPayloadType.disconnect) {
      final reason = payload.message ?? '';
      final currentDev = state.activeDevice;
      _manualDisconnect = true;
      _cleanupTimers();
      unawaited(_socketClient.disconnect());
      _restoreLocalNotificationAndDiscordState();
      ref.read(isDualPlaybackEnabledProvider.notifier).resetOnDisconnect();

      if (reason == 'revoked' && currentDev != null) {
        unawaited(
          ref
              .read(connectDiscoveryProvider.notifier)
              .markDeviceUnpaired(currentDev.id),
        );
        ref.read(notificationProvider.notifier).showNotification(
              'Resonance Connect',
              'Access was revoked by ${currentDev.name}.',
              silentOsNotification: true,
            );
      } else if (reason == 'host_stopped' && currentDev != null) {
        ref.read(notificationProvider.notifier).showNotification(
              'Resonance Connect',
              '${currentDev.name} stopped Host Mode.',
              silentOsNotification: true,
            );
      }

      state = const ConnectClientState(status: ConnectStatus.disconnected);
    } else if (payload.type == ConnectPayloadType.error &&
        payload.message != null) {
      state = state.copyWith(errorMessage: payload.message);
    }
  }

  void _onSocketStateChanged(bool connected) {
    if (!connected && !_manualDisconnect && state.activeDevice != null) {
      _scheduleAutoReconnect();
    }
  }

  void _scheduleAutoReconnect() {
    if (_reconnectAttempts >= 3 || state.activeDevice == null) {
      _cleanupTimers();
      _restoreLocalNotificationAndDiscordState();
      ref.read(isDualPlaybackEnabledProvider.notifier).resetOnDisconnect();
      state = state.copyWith(
        status: ConnectStatus.disconnected,
        clearRemoteSync: true,
        errorMessage:
            'Lost connection to ${state.activeDevice?.name ?? 'Desktop'}.',
      );
      return;
    }

    _reconnectAttempts++;
    final delaySec = _reconnectAttempts * 2;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () async {
      final dev = state.activeDevice;
      if (dev == null || _manualDisconnect) return;
      final store = ref.read(connectPairedDevicesStoreProvider);
      final token = dev.authToken ?? store.getPairedHostById(dev.id)?.authToken;
      if (token == null) return;
      try {
        await _socketClient.connect(
          device: dev,
          authToken: token,
          clientId: store.localDeviceId,
          clientName: store.localDeviceName,
        );
        _reconnectAttempts = 0;
      } catch (_) {
        _scheduleAutoReconnect();
      }
    });
  }

  /// Synchronizes the Android OS MediaSession Notification and Lockscreen controls
  /// with the Desktop Host ONLY when in Single Remote Mode (`!isDualPlaybackEnabled`).
  void _syncRemoteNotificationState(ConnectPlaybackSync sync, Duration pos) {
    if (!Platform.isAndroid) return;
    final isDual = ref.read(isDualPlaybackEnabledProvider);
    if (isDual) {
      // Excluded in Dual Mode: OS Notification stays 100% focused on Android Local
      return;
    }

    try {
      final handler = ref.read(audioHandlerProvider);
      handler.onRemotePlay = play;
      handler.onRemotePause = pause;
      handler.onRemoteSkipToNext = skipToNext;
      handler.onRemoteSkipToPrevious = skipToPrevious;
      handler.onRemoteSeek = seek;

      final track = sync.currentTrack;
      final dur = sync.duration;
      audio_svc.MediaItem? svcItem;
      if (track != null) {
        Uri? artUri;
        if (track.thumbnailUrl != null && track.thumbnailUrl!.isNotEmpty) {
          artUri = track.thumbnailUrl!.startsWith('http')
              ? Uri.tryParse(track.thumbnailUrl!)
              : Uri.file(track.thumbnailUrl!);
        }
        svcItem = audio_svc.MediaItem(
          id: track.id ?? track.path,
          title: track.title,
          artist: '${track.artist ?? 'Unknown Artist'} • ${sync.hostName}',
          album: track.album ?? sync.hostName,
          duration: dur > Duration.zero ? dur : track.duration,
          artUri: artUri,
        );
      }

      handler.syncRemotePlayback(
        remoteMediaItem: svcItem,
        playing: sync.isPlaying,
        loading: sync.isLoading,
        position: pos,
        duration: dur,
        speed: sync.playbackRate,
      );
    } catch (_) {}
  }

  /// Restores Android's local OS MediaSession Notification and Discord RPC state
  /// when disconnecting from Desktop or when enabling Dual Progress Bar Mode.
  void _restoreLocalNotificationAndDiscordState() {
    try {
      final localAudio = ref.read(audioProvider);
      final localTrack = localAudio.currentTrack;
      final localDur = localAudio.duration > Duration.zero
          ? localAudio.duration
          : (localTrack?.duration ?? Duration.zero);

      if (Platform.isAndroid) {
        final handler = ref.read(audioHandlerProvider);
        audio_svc.MediaItem? restoredItem;
        if (localTrack != null) {
          Uri? artUri;
          if (localTrack.thumbnailUrl != null &&
              localTrack.thumbnailUrl!.isNotEmpty) {
            artUri = localTrack.thumbnailUrl!.startsWith('http')
                ? Uri.tryParse(localTrack.thumbnailUrl!)
                : Uri.file(localTrack.thumbnailUrl!);
          }
          restoredItem = audio_svc.MediaItem(
            id: localTrack.id ?? localTrack.path,
            title: localTrack.title,
            artist: localTrack.artist ?? 'Unknown Artist',
            album: localTrack.album ?? '',
            duration: localDur,
            artUri: artUri,
          );
        }
        handler.exitRemoteMode(
          restoredLocalItem: restoredItem,
          localPlaying: localAudio.isPlaying,
          localPosition: localAudio.position,
          localDuration: localDur,
          localSpeed: localAudio.speed,
        );
      }

      final rpc = ref.read(discordRpcServiceProvider);
      if (_isPublishingRemoteDiscordRpc) {
        _isPublishingRemoteDiscordRpc = false;
        if (localTrack != null && localAudio.isPlaying) {
          unawaited(
            rpc.updatePresence(
              localTrack,
              localAudio.position,
              localDur,
              localAudio.isPlaying,
            ),
          );
        } else {
          rpc.clearPresence();
        }
      }
    } catch (_) {}
  }

  /// Handles 3-scenario Cross-Device Discord RPC Failover:
  /// 1. When Windows Discord RPC is active (`sync.isHostDiscordRpcActive == true`), Android stays silent.
  /// 2. When Windows Discord RPC is inactive (Discord Desktop off or Windows offline) and Android has internet,
  ///    Android publishes the Now Playing status to Discord RPC (unless Dual Mode is active and Android is playing locally).
  void _syncRemoteDiscordFailover(ConnectPlaybackSync sync, Duration pos) {
    try {
      final isDual = ref.read(isDualPlaybackEnabledProvider);
      final localAudio = ref.read(audioProvider);

      // Exclusion in Dual Mode: if Android is playing local music, local song owns Discord RPC.
      if (isDual && localAudio.isPlaying) {
        _isPublishingRemoteDiscordRpc = false;
        return;
      }

      final rpc = ref.read(discordRpcServiceProvider);
      if (sync.isHostDiscordRpcActive || sync.currentTrack == null) {
        if (_isPublishingRemoteDiscordRpc) {
          _isPublishingRemoteDiscordRpc = false;
          rpc.clearPresence();
        }
        return;
      }

      _isPublishingRemoteDiscordRpc = true;
      unawaited(
        rpc.syncRemoteTrackPresence(
          sync.currentTrack,
          position: pos,
          duration: sync.duration,
          isPlaying: sync.isPlaying,
        ),
      );
    } catch (_) {}
  }

  /// Runs a 25-second recovery check ONLY when a remote track is actively playing
  /// and neither Windows nor Android has confirmed Discord RPC yet (Scenario 3: Discord opened mid-song).
  void _syncDiscordRecoveryWatchdog() {
    final sync = state.remoteSync;
    final shouldWatch = state.isActiveRemote &&
        sync != null &&
        sync.isPlaying &&
        !sync.isHostDiscordRpcActive;

    if (!shouldWatch) {
      _discordRecoveryTimer?.cancel();
      _discordRecoveryTimer = null;
      return;
    }

    if (_discordRecoveryTimer?.isActive == true) return;

    _discordRecoveryTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) {
        final currentSync = state.remoteSync;
        if (!state.isActiveRemote ||
            currentSync == null ||
            !currentSync.isPlaying ||
            currentSync.isHostDiscordRpcActive) {
          _discordRecoveryTimer?.cancel();
          _discordRecoveryTimer = null;
          return;
        }
        final rpc = ref.read(discordRpcServiceProvider);
        if (!rpc.isPresenceActive) {
          _syncRemoteDiscordFailover(
            currentSync,
            currentSync.computePositionAt(),
          );
        }
      },
    );
  }

  /// Starts the 250ms clock-interpolation timer ONLY when remote playback is actively playing,
  /// and cancels it immediately when paused, loading, or disconnected (0 idle CPU wakeups).
  void _syncInterpolationTicker() {
    final sync = state.remoteSync;
    final shouldTick = state.isActiveRemote &&
        sync != null &&
        sync.isPlaying &&
        !sync.isLoading;

    if (!shouldTick) {
      _clockInterpolationTimer?.cancel();
      _clockInterpolationTimer = null;
      return;
    }

    if (_clockInterpolationTimer?.isActive == true) return;

    _clockInterpolationTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        final currentSync = state.remoteSync;
        if (currentSync == null ||
            !currentSync.isPlaying ||
            currentSync.isLoading) {
          _clockInterpolationTimer?.cancel();
          _clockInterpolationTimer = null;
          return;
        }
        final nextPos = currentSync.computePositionAt();
        if ((nextPos.inMilliseconds -
                    state.interpolatedPosition.inMilliseconds)
                .abs() >=
            200) {
          state = state.copyWith(interpolatedPosition: nextPos);
        }
      },
    );
  }

  // ── Remote Control Command Dispatchers ─────────────────────────────────────

  void togglePlayPause() {
    final current = state.remoteSync;
    if (current != null) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final currentPosMs =
          current.computePositionAt(nowMs: nowMs).inMilliseconds;
      final optimistic = ConnectPlaybackSync(
        currentTrack: current.currentTrack,
        isPlaying: !current.isPlaying,
        isLoading: current.isLoading,
        positionMs: currentPosMs,
        durationMs: current.durationMs,
        anchorTimestampMs: nowMs,
        playbackRate: current.playbackRate,
        pitch: current.pitch,
        volume: current.volume,
        loopMode: current.loopMode,
        isShuffleEnabled: current.isShuffleEnabled,
        queue: current.queue,
        currentIndex: current.currentIndex,
        nextTrack: current.nextTrack,
        hostName: current.hostName,
        isHostDiscordRpcActive: current.isHostDiscordRpcActive,
      );
      final pos = Duration(milliseconds: currentPosMs);
      state = state.copyWith(
        remoteSync: optimistic,
        interpolatedPosition: pos,
      );
      _syncInterpolationTicker();
      _syncRemoteNotificationState(optimistic, pos);
    }
    _socketClient.sendCommand(
      const ConnectCommand(action: ConnectCommandAction.togglePlayPause),
    );
  }

  void play() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.play),
      );

  void pause() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.pause),
      );

  void skipToNext() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.next),
      );

  void skipToPrevious() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.previous),
      );

  void seek(Duration position) {
    final current = state.remoteSync;
    if (current != null) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final optimistic = ConnectPlaybackSync(
        currentTrack: current.currentTrack,
        isPlaying: current.isPlaying,
        isLoading: current.isLoading,
        positionMs: position.inMilliseconds,
        durationMs: current.durationMs,
        anchorTimestampMs: nowMs,
        playbackRate: current.playbackRate,
        pitch: current.pitch,
        volume: current.volume,
        loopMode: current.loopMode,
        isShuffleEnabled: current.isShuffleEnabled,
        queue: current.queue,
        currentIndex: current.currentIndex,
        nextTrack: current.nextTrack,
        hostName: current.hostName,
        isHostDiscordRpcActive: current.isHostDiscordRpcActive,
      );
      state = state.copyWith(
        remoteSync: optimistic,
        interpolatedPosition: position,
      );
      _syncRemoteNotificationState(optimistic, position);
    }
    _socketClient.sendCommand(
      ConnectCommand(
        action: ConnectCommandAction.seek,
        positionMs: position.inMilliseconds,
      ),
    );
  }

  void setVolume(double volume) {
    final clamped = volume.clamp(0.0, 100.0);
    final current = state.remoteSync;
    if (current != null) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final optimistic = ConnectPlaybackSync(
        currentTrack: current.currentTrack,
        isPlaying: current.isPlaying,
        isLoading: current.isLoading,
        positionMs: current.computePositionAt(nowMs: nowMs).inMilliseconds,
        durationMs: current.durationMs,
        anchorTimestampMs: nowMs,
        playbackRate: current.playbackRate,
        pitch: current.pitch,
        volume: clamped,
        loopMode: current.loopMode,
        isShuffleEnabled: current.isShuffleEnabled,
        queue: current.queue,
        currentIndex: current.currentIndex,
        nextTrack: current.nextTrack,
        hostName: current.hostName,
        isHostDiscordRpcActive: current.isHostDiscordRpcActive,
      );
      state = state.copyWith(remoteSync: optimistic);
    }
    _volumeSendDebounceTimer?.cancel();
    _volumeSendDebounceTimer = Timer(
      const Duration(milliseconds: 45),
      () {
        _socketClient.sendCommand(
          ConnectCommand(
            action: ConnectCommandAction.setVolume,
            volume: clamped,
          ),
        );
      },
    );
  }

  void setSpeed(double speed) {
    final clamped = speed.clamp(0.25, 2.0);
    final current = state.remoteSync;
    if (current != null) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final optimistic = ConnectPlaybackSync(
        currentTrack: current.currentTrack,
        isPlaying: current.isPlaying,
        isLoading: current.isLoading,
        positionMs: current.computePositionAt(nowMs: nowMs).inMilliseconds,
        durationMs: current.durationMs,
        anchorTimestampMs: nowMs,
        playbackRate: clamped,
        pitch: current.pitch,
        volume: current.volume,
        loopMode: current.loopMode,
        isShuffleEnabled: current.isShuffleEnabled,
        queue: current.queue,
        currentIndex: current.currentIndex,
        nextTrack: current.nextTrack,
        hostName: current.hostName,
        isHostDiscordRpcActive: current.isHostDiscordRpcActive,
      );
      state = state.copyWith(remoteSync: optimistic);
    }
    _speedSendDebounceTimer?.cancel();
    _speedSendDebounceTimer = Timer(
      const Duration(milliseconds: 45),
      () {
        _socketClient.sendCommand(
          ConnectCommand(
            action: ConnectCommandAction.setSpeed,
            speed: clamped,
          ),
        );
      },
    );
  }

  void setPitch(double pitch) {
    final clamped = pitch.clamp(-12.0, 12.0);
    final current = state.remoteSync;
    if (current != null) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final optimistic = ConnectPlaybackSync(
        currentTrack: current.currentTrack,
        isPlaying: current.isPlaying,
        isLoading: current.isLoading,
        positionMs: current.computePositionAt(nowMs: nowMs).inMilliseconds,
        durationMs: current.durationMs,
        anchorTimestampMs: nowMs,
        playbackRate: current.playbackRate,
        pitch: clamped,
        volume: current.volume,
        loopMode: current.loopMode,
        isShuffleEnabled: current.isShuffleEnabled,
        queue: current.queue,
        currentIndex: current.currentIndex,
        nextTrack: current.nextTrack,
        hostName: current.hostName,
        isHostDiscordRpcActive: current.isHostDiscordRpcActive,
      );
      state = state.copyWith(remoteSync: optimistic);
    }
    _pitchSendDebounceTimer?.cancel();
    _pitchSendDebounceTimer = Timer(
      const Duration(milliseconds: 45),
      () {
        _socketClient.sendCommand(
          ConnectCommand(
            action: ConnectCommandAction.setPitch,
            pitch: clamped,
          ),
        );
      },
    );
  }

  void toggleShuffle() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.toggleShuffle),
      );

  void cycleLoopMode() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.cycleLoopMode),
      );

  void jumpToQueueIndex(int index) => _socketClient.sendCommand(
        ConnectCommand(
          action: ConnectCommandAction.jumpToQueueIndex,
          index: index,
        ),
      );

  void removeTrackFromQueue(int index) => _socketClient.sendCommand(
        ConnectCommand(
          action: ConnectCommandAction.removeTrackFromQueue,
          index: index,
        ),
      );

  void reorderQueue(int oldIndex, int newIndex) => _socketClient.sendCommand(
        ConnectCommand(
          action: ConnectCommandAction.reorderQueue,
          oldIndex: oldIndex,
          newIndex: newIndex,
        ),
      );

  void clearUpcomingQueue() => _socketClient.sendCommand(
        const ConnectCommand(action: ConnectCommandAction.clearUpcomingQueue),
      );

  void playTrackOnRemote(MediaItem track) => _socketClient.sendCommand(
        ConnectCommand(
          action: ConnectCommandAction.playTrack,
          track: track,
        ),
      );

  void addToRemoteQueue(MediaItem track) => _socketClient.sendCommand(
        ConnectCommand(
          action: ConnectCommandAction.addToQueue,
          track: track,
        ),
      );

  void playNextOnRemote(MediaItem track) => _socketClient.sendCommand(
        ConnectCommand(
          action: ConnectCommandAction.playNext,
          track: track,
        ),
      );
}
