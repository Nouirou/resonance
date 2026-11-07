import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/models/connect_payload.dart';
import '../storage/connect_paired_devices_store.dart';
import 'connect_auth_interceptor.dart';

class ConnectedClientSession {
  final String clientId;
  final String clientName;
  final String remoteIp;
  final WebSocketChannel channel;
  final DateTime connectedAt;
  StreamSubscription? subscription;

  ConnectedClientSession({
    required this.clientId,
    required this.clientName,
    required this.remoteIp,
    required this.channel,
    required this.connectedAt,
    this.subscription,
  });
}

typedef ArtworkByteResolver = Future<Uint8List?> Function(String trackId);
typedef InitialSyncProvider = ConnectPayload Function();
typedef ClientUnpairedCallback = Future<void> Function(String clientId);

class ConnectShelfServer {
  static const int defaultBasePort = 52026;
  static const int maxPortAttempts = 10;

  final ConnectPairedDevicesStore _store;
  final ConnectAuthInterceptor _auth;
  final ArtworkByteResolver? onResolveArtwork;
  final InitialSyncProvider? onBuildInitialSync;
  final ClientUnpairedCallback? onClientUnpaired;

  HttpServer? _server;
  int? _boundPort;
  final Map<WebSocketChannel, ConnectedClientSession> _sessions = {};

  final StreamController<ConnectCommand> _commandController =
      StreamController<ConnectCommand>.broadcast();
  final StreamController<List<ConnectedClientSession>> _sessionsController =
      StreamController<List<ConnectedClientSession>>.broadcast();

  ConnectShelfServer({
    required ConnectPairedDevicesStore store,
    this.onResolveArtwork,
    this.onBuildInitialSync,
    this.onClientUnpaired,
  })  : _store = store,
        _auth = ConnectAuthInterceptor(store);

  bool get isRunning => _server != null;
  int? get port => _boundPort;
  List<ConnectedClientSession> get activeSessions =>
      List.unmodifiable(_sessions.values);
  Stream<ConnectCommand> get commandStream => _commandController.stream;
  Stream<List<ConnectedClientSession>> get sessionsStream =>
      _sessionsController.stream;

  /// Starts the embedded Shelf HTTP + WebSocket server on [preferredPort]
  /// (falling back to subsequent ports if occupied).
  Future<int> start({int preferredPort = defaultBasePort}) async {
    if (_server != null && _boundPort != null) {
      return _boundPort!;
    }

    final router = Router();

    // 1. Public Host Discovery Info Endpoint (also validates optional `token` query param)
    router.get('/info', (Request req) {
      final tokenParam = req.url.queryParameters['token']?.trim();
      final bool? isTokenValid = (tokenParam != null && tokenParam.isNotEmpty)
          ? _store.isClientTokenTrusted(tokenParam)
          : null;
      return Response.ok(
        jsonEncode({
          'id': _store.localDeviceId,
          'name': _store.localDeviceName,
          'version': '1.0.0',
          'port': _boundPort ?? preferredPort,
          'requiresPairing': true,
          'isTokenValid': ?isTokenValid,
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    // 2. Pairing Handshake Endpoint (PIN or QR Token -> Returns Persistent Auth Token)
    router.post('/pair', (Request req) async {
      try {
        final bodyStr = await req.readAsString();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final pin = body['pin'] as String?;
        final qrToken = body['qrToken'] as String?;
        final clientId = body['clientId'] as String? ?? 'mobile_client';
        final clientName = body['clientName'] as String? ?? 'Phone Controller';

        final isValid = _auth.verifyPairingCredentials(
          pin: pin,
          qrToken: qrToken,
        );
        if (!isValid) {
          return Response.forbidden(
            jsonEncode({
              'error': 'Invalid pairing PIN or expired QR token.',
            }),
            headers: {'content-type': 'application/json'},
          );
        }

        final record = await _store.registerTrustedClient(
          clientId: clientId,
          clientName: clientName,
        );

        debugPrint('[Connect] Paired remote client: $clientName ($clientId)');
        return Response.ok(
          jsonEncode({
            'id': _store.localDeviceId,
            'name': _store.localDeviceName,
            'version': '1.0.0',
            'port': _boundPort ?? preferredPort,
            'authToken': record.token,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Malformed pairing payload: $e'}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 3. Mutual Unpair Endpoint (Client notifies Host that it forgot/removed this Host)
    router.post('/unpair', (Request req) async {
      try {
        final bodyStr = await req.readAsString();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final clientId = body['clientId'] as String? ?? '';
        final token = body['authToken'] as String? ?? '';

        if (clientId.isNotEmpty && _store.isClientTokenTrusted(token)) {
          await _store.revokeTrustedClient(clientId);
          await disconnectClient(clientId, reason: 'unpaired');
          if (onClientUnpaired != null) {
            await onClientUnpaired!(clientId);
          }
          debugPrint('[Connect] Client $clientId unpaired from host.');
        }
        return Response.ok(
          jsonEncode({'status': 'unpaired'}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Malformed unpair payload: $e'}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 4. Local Artwork Proxy Route (Serves embedded/cached artwork bytes to LAN client)
    router.get('/art/<trackId>', (Request req, String trackId) async {
      if (onResolveArtwork == null) {
        return Response.notFound('Artwork resolver unavailable');
      }
      final decodedId = Uri.decodeComponent(trackId);
      final bytes = await onResolveArtwork!(decodedId);
      if (bytes == null || bytes.isEmpty) {
        return Response.notFound('Artwork not found');
      }
      return Response.ok(
        bytes,
        headers: {
          'content-type': 'image/jpeg',
          'cache-control': 'public, max-age=3600',
        },
      );
    });

    // 5. Authenticated Real-Time WebSocket Endpoint
    router.get('/ws', (Request request) {
      if (!_auth.isAuthorizedRequest(request)) {
        return Response(
          HttpStatus.unauthorized,
          body: jsonEncode({'error': 'Unauthorized: Pairing required.'}),
          headers: {'content-type': 'application/json'},
        );
      }

      final clientId =
          request.url.queryParameters['clientId']?.trim() ?? 'client_unknown';
      final clientName =
          request.url.queryParameters['clientName']?.trim() ?? 'Mobile Remote';
      final connInfo =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final remoteIp = connInfo?.remoteAddress.address ?? 'unknown';

      final wsHandler = webSocketHandler((WebSocketChannel webSocket, _) {
        _handleClientConnected(
          webSocket: webSocket,
          clientId: clientId,
          clientName: clientName,
          remoteIp: remoteIp,
        );
      });

      return wsHandler(request);
    });

    Object? lastError;
    for (int i = 0; i < maxPortAttempts; i++) {
      final candidatePort = preferredPort + i;
      try {
        final srv = await shelf_io.serve(
          router.call,
          InternetAddress.anyIPv4,
          candidatePort,
        );
        _server = srv;
        _boundPort = srv.port;
        debugPrint(
          '[Connect] Host WebSocket Server listening on 0.0.0.0:${srv.port}',
        );
        return srv.port;
      } catch (e) {
        lastError = e;
      }
    }

    throw StateError(
      'Failed to bind Resonance Connect server on ports '
      '$preferredPort..${preferredPort + maxPortAttempts - 1}: $lastError',
    );
  }

  void _handleClientConnected({
    required WebSocketChannel webSocket,
    required String clientId,
    required String clientName,
    required String remoteIp,
  }) {
    // Evict any stale/ghost socket for the same clientId before registering the new session
    final staleEntries = _sessions.entries
        .where((e) => e.value.clientId == clientId && e.key != webSocket)
        .toList();
    for (final stale in staleEntries) {
      _sessions.remove(stale.key);
      stale.value.subscription?.cancel();
      try {
        stale.key.sink.close();
      } catch (_) {}
    }

    final session = ConnectedClientSession(
      clientId: clientId,
      clientName: clientName,
      remoteIp: remoteIp,
      channel: webSocket,
      connectedAt: DateTime.now(),
    );
    _sessions[webSocket] = session;
    _notifySessionsUpdated();

    if (onBuildInitialSync != null) {
      try {
        final snapshot = onBuildInitialSync!();
        webSocket.sink.add(snapshot.encode());
      } catch (e) {
        debugPrint('[Connect] Failed sending initial snapshot: $e');
      }
    }

    session.subscription = webSocket.stream.listen(
      (dynamic rawMessage) {
        if (rawMessage is! String) return;
        final payload = ConnectPayload.tryDecode(rawMessage);
        if (payload == null) return;

        switch (payload.type) {
          case ConnectPayloadType.ping:
            try {
              webSocket.sink.add(ConnectPayload.pong().encode());
            } catch (_) {}
            break;
          case ConnectPayloadType.disconnect:
            final removed = _sessions.remove(webSocket);
            removed?.subscription?.cancel();
            _notifySessionsUpdated();
            break;
          case ConnectPayloadType.command:
            final cmd = payload.command;
            if (cmd != null) {
              if (cmd.action == ConnectCommandAction.requestSync &&
                  onBuildInitialSync != null) {
                try {
                  webSocket.sink.add(onBuildInitialSync!().encode());
                } catch (_) {}
              } else {
                _commandController.add(cmd);
              }
            }
            break;
          default:
            break;
        }
      },
      onDone: () {
        final removed = _sessions.remove(webSocket);
        removed?.subscription?.cancel();
        _notifySessionsUpdated();
      },
      onError: (_) {
        final removed = _sessions.remove(webSocket);
        removed?.subscription?.cancel();
        _notifySessionsUpdated();
      },
    );
  }

  /// Broadcasts a [ConnectPayload] to all currently connected remote controllers.
  void broadcast(ConnectPayload payload) {
    if (_sessions.isEmpty) return;
    final encoded = payload.encode();
    final deadSockets = <WebSocketChannel>[];

    for (final entry in _sessions.entries) {
      try {
        entry.key.sink.add(encoded);
      } catch (_) {
        deadSockets.add(entry.key);
      }
    }

    if (deadSockets.isNotEmpty) {
      for (final dead in deadSockets) {
        final removed = _sessions.remove(dead);
        removed?.subscription?.cancel();
      }
      _notifySessionsUpdated();
    }
  }

  /// Sends an explicit `disconnect` frame (`reason: 'revoked'` by default) to the client
  /// before closing its WebSocket so the client knows not to auto-reconnect and can wipe its dead token.
  Future<void> disconnectClient(
    String clientId, {
    String reason = 'revoked',
  }) async {
    final targets = _sessions.entries
        .where((e) => e.value.clientId == clientId)
        .map((e) => e.key)
        .toList();
    final disconnectFrame = ConnectPayload.disconnect(reason).encode();
    for (final ws in targets) {
      final removed = _sessions.remove(ws);
      await removed?.subscription?.cancel();
      try {
        ws.sink.add(disconnectFrame);
        await ws.sink.close();
      } catch (_) {}
    }
    if (targets.isNotEmpty) {
      _notifySessionsUpdated();
    }
  }

  void _notifySessionsUpdated() {
    if (!_sessionsController.isClosed) {
      _sessionsController.add(activeSessions);
    }
  }

  Future<void> stop() async {
    final sessionsList = List<ConnectedClientSession>.from(_sessions.values);
    _sessions.clear();
    _notifySessionsUpdated();

    final stopFrame = ConnectPayload.disconnect('host_stopped').encode();
    for (final s in sessionsList) {
      await s.subscription?.cancel();
      try {
        s.channel.sink.add(stopFrame);
        await s.channel.sink.close();
      } catch (_) {}
    }

    final srv = _server;
    _server = null;
    _boundPort = null;
    if (srv != null) {
      await srv.close(force: true);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _commandController.close();
    await _sessionsController.close();
  }
}
