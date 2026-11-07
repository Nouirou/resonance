import 'package:shelf/shelf.dart';
import '../storage/connect_paired_devices_store.dart';

class ConnectAuthInterceptor {
  final ConnectPairedDevicesStore _store;

  const ConnectAuthInterceptor(this._store);

  /// Validates whether an incoming WebSocket or HTTP request carries a valid
  /// paired client token or active QR session token.
  bool isAuthorizedRequest(Request request) {
    final queryToken = request.url.queryParameters['token']?.trim();
    if (queryToken != null && _store.isClientTokenTrusted(queryToken)) {
      return true;
    }

    final authHeader = request.headers['authorization'] ??
        request.headers['Authorization'];
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      final bearerToken = authHeader.substring(7).trim();
      if (_store.isClientTokenTrusted(bearerToken)) {
        return true;
      }
    }

    return false;
  }

  /// Validates a pairing request using either the 4-digit PIN or the QR code session token.
  bool verifyPairingCredentials({
    String? pin,
    String? qrToken,
  }) {
    if (qrToken != null &&
        qrToken.isNotEmpty &&
        qrToken.trim() == _store.qrSessionToken) {
      return true;
    }
    if (pin != null &&
        pin.isNotEmpty &&
        pin.trim() == _store.pairingPin) {
      return true;
    }
    return false;
  }
}

