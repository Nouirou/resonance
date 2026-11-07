enum ConnectStatus {
  disconnected,
  connecting,
  pairingRequired,
  connected,
  activeRemote,
  error,
}

class PendingPairRequest {
  final String clientId;
  final String clientName;
  final String remoteIp;
  final String verificationPin;
  final DateTime requestedAt;

  const PendingPairRequest({
    required this.clientId,
    required this.clientName,
    required this.remoteIp,
    required this.verificationPin,
    required this.requestedAt,
  });
}

