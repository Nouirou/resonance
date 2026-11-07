import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/errors/connect_exception.dart';
import '../../domain/models/connect_device.dart';
import '../../domain/models/connect_payload.dart';

class ConnectSocketClient {
  static const Duration heartbeatInterval = Duration(seconds: 10);

  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  Timer? _heartbeatTimer;
  bool _isConnected = false;

  final StreamController<ConnectPayload> _payloadController =
      StreamController<ConnectPayload>.broadcast();
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();

  bool get isConnected => _isConnected;
  Stream<ConnectPayload> get payloadStream => _payloadController.stream;
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  /// Probes a host `GET /info` endpoint to verify reachability, fetch host metadata,
  /// and optionally verify if an existing [savedAuthToken] is still trusted on the host.
  static Future<ConnectDevice?> probeHost({
    required String ip,
    required int port,
    String? savedAuthToken,
    ConnectDiscoveryMethod method = ConnectDiscoveryMethod.manualIp,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final uri = Uri.http(
        '$ip:$port',
        '/info',
        savedAuthToken != null && savedAuthToken.isNotEmpty
            ? {'token': savedAuthToken}
            : null,
      );
      final response = await http.get(uri).timeout(timeout);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final isTokenValid = data['isTokenValid'] as bool?;
        final stillPaired = isTokenValid == true &&
            savedAuthToken != null &&
            savedAuthToken.isNotEmpty;

        return ConnectDevice(
          id: data['id'] as String? ?? 'host_$ip',
          name: data['name'] as String? ?? 'Desktop PC',
          ip: ip,
          port: (data['port'] as num?)?.toInt() ?? port,
          version: data['version'] as String? ?? '1.0.0',
          isPaired: stillPaired,
          authToken: stillPaired ? savedAuthToken : null,
          discoveryMethod: method,
          lastSeen: DateTime.now(),
        );
      }
    } catch (_) {}
    return null;
  }

  /// Notifies the Desktop Host (`POST /unpair`) that this client forgot/removed the pairing,
  /// so the Desktop Host also removes this client from its `Remembered Mobile Remotes`.
  static Future<void> unpairFromHost({
    required ConnectDevice device,
    required String clientId,
  }) async {
    final token = device.authToken;
    if (token == null || token.isEmpty) return;
    try {
      final uri = Uri.http('${device.ip}:${device.port}', '/unpair');
      await http
          .post(
            uri,
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'clientId': clientId,
              'authToken': token,
            }),
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Executes HTTP `POST /pair` handshake with either a 4-digit [pin] or [qrToken]
  /// and returns the paired [ConnectDevice] carrying a persistent `authToken`.
  static Future<ConnectDevice> pairWithHost({
    required ConnectDevice device,
    String? pin,
    String? qrToken,
    required String clientId,
    required String clientName,
  }) async {
    final uri = device.buildPairUri();
    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              if (pin != null) 'pin': pin.trim(),
              if (qrToken != null) 'qrToken': qrToken.trim(),
              'clientId': clientId,
              'clientName': clientName,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      throw ConnectException(
        'Cannot reach host at ${device.endpoint}. Check Wi-Fi and firewall.',
        code: 'HOST_UNREACHABLE',
        cause: e,
      );
    }

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['authToken'] as String?;
      if (token == null || token.isEmpty) {
        throw const ConnectException(
          'Host returned empty authentication token.',
          code: 'INVALID_HOST_RESPONSE',
        );
      }
      return device.copyWith(
        id: data['id'] as String? ?? device.id,
        name: data['name'] as String? ?? device.name,
        version: data['version'] as String? ?? device.version,
        isPaired: true,
        authToken: token,
        lastSeen: DateTime.now(),
      );
    } else if (response.statusCode == 403) {
      throw const ConnectException(
        'Incorrect 4-digit PIN or expired QR code.',
        code: 'INVALID_PIN',
      );
    } else {
      throw ConnectException(
        'Pairing failed (HTTP ${response.statusCode}).',
        code: 'PAIR_FAILED',
      );
    }
  }

  /// Connects to an authenticated Desktop Host WebSocket endpoint.
  Future<void> connect({
    required ConnectDevice device,
    required String authToken,
    required String clientId,
    required String clientName,
  }) async {
    await disconnect();

    final wsUri = device.buildWebSocketUri(
      token: authToken,
      clientId: clientId,
      clientName: clientName,
    );

    try {
      final channel = WebSocketChannel.connect(wsUri);
      await channel.ready.timeout(const Duration(seconds: 5));
      _channel = channel;
      _setConnected(true);

      _socketSub = channel.stream.listen(
        (dynamic message) {
          if (message is! String) return;
          final payload = ConnectPayload.tryDecode(message);
          if (payload != null && !_payloadController.isClosed) {
            _payloadController.add(payload);
          }
        },
        onDone: () {
          _handleSocketClosed();
        },
        onError: (Object error) {
          debugPrint('[Connect] Socket error: $error');
          _handleSocketClosed();
        },
      );

      // Start periodic heartbeat
      _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
        sendPayload(ConnectPayload.ping());
      });

      // Request initial state sync
      sendCommand(
        const ConnectCommand(action: ConnectCommandAction.requestSync),
      );
    } catch (e) {
      _handleSocketClosed();
      throw ConnectException(
        'Failed to open WebSocket to ${device.name} (${device.endpoint}).',
        code: 'WS_CONNECT_FAILED',
        cause: e,
      );
    }
  }

  void sendCommand(ConnectCommand command) {
    sendPayload(ConnectPayload.command(command));
  }

  void sendPayload(ConnectPayload payload) {
    final ch = _channel;
    if (ch == null || !_isConnected) return;
    try {
      ch.sink.add(payload.encode());
    } catch (e) {
      debugPrint('[Connect] Send error: $e');
    }
  }

  void _handleSocketClosed() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _channel = null;
    if (_isConnected) {
      _setConnected(false);
    }
  }

  void _setConnected(bool value) {
    _isConnected = value;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(value);
    }
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    final ch = _channel;
    _channel = null;
    if (_isConnected) {
      _setConnected(false);
    }
    if (ch != null) {
      try {
        ch.sink.add(ConnectPayload.disconnect('client_closed').encode());
        await ch.sink.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _payloadController.close();
    await _connectionStateController.close();
  }
}
