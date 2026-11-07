enum ConnectDiscoveryMethod {
  mdns,
  udpBeacon,
  qrCode,
  manualIp,
  pairedHistory,
}

class ConnectDevice {
  final String id;
  final String name;
  final String ip;
  final int port;
  final String version;
  final bool isPaired;
  final String? authToken;
  final ConnectDiscoveryMethod discoveryMethod;
  final DateTime lastSeen;

  const ConnectDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.version = '1.0.0',
    this.isPaired = false,
    this.authToken,
    this.discoveryMethod = ConnectDiscoveryMethod.mdns,
    required this.lastSeen,
  });

  String get endpoint => '$ip:$port';

  Uri buildWebSocketUri({
    required String token,
    required String clientId,
    required String clientName,
  }) {
    return Uri(
      scheme: 'ws',
      host: ip,
      port: port,
      path: '/ws',
      queryParameters: {
        'token': token,
        'clientId': clientId,
        'clientName': clientName,
      },
    );
  }

  Uri buildPairUri() => Uri.http('$ip:$port', '/pair');
  Uri buildInfoUri() => Uri.http('$ip:$port', '/info');
  Uri buildArtworkUri(String trackId) => Uri.http(
        '$ip:$port',
        '/art/${Uri.encodeComponent(trackId)}',
      );

  ConnectDevice copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    String? version,
    bool? isPaired,
    String? authToken,
    bool clearAuthToken = false,
    ConnectDiscoveryMethod? discoveryMethod,
    DateTime? lastSeen,
  }) {
    return ConnectDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      version: version ?? this.version,
      isPaired: isPaired ?? this.isPaired,
      authToken: clearAuthToken ? null : (authToken ?? this.authToken),
      discoveryMethod: discoveryMethod ?? this.discoveryMethod,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'ip': ip,
      'port': port,
      'version': version,
      'isPaired': isPaired,
      'authToken': authToken,
      'discoveryMethod': discoveryMethod.name,
      'lastSeenMs': lastSeen.millisecondsSinceEpoch,
    };
  }

  factory ConnectDevice.fromJson(Map<String, dynamic> json) {
    final methodStr = json['discoveryMethod'] as String?;
    final method = ConnectDiscoveryMethod.values.firstWhere(
      (m) => m.name == methodStr,
      orElse: () => ConnectDiscoveryMethod.pairedHistory,
    );
    return ConnectDevice(
      id: json['id'] as String? ?? 'unknown',
      name: json['name'] as String? ?? 'Desktop Host',
      ip: json['ip'] as String? ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 52026,
      version: json['version'] as String? ?? '1.0.0',
      isPaired: json['isPaired'] as bool? ?? false,
      authToken: json['authToken'] as String?,
      discoveryMethod: method,
      lastSeen: json['lastSeenMs'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['lastSeenMs'] as num).toInt(),
            )
          : DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConnectDevice &&
        other.id == id &&
        other.ip == ip &&
        other.port == port &&
        other.name == name &&
        other.isPaired == isPaired;
  }

  @override
  int get hashCode => Object.hash(id, ip, port, name, isPaired);
}

