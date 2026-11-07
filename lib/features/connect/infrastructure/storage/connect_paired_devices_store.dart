import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/data/services/storage_service.dart';
import '../../domain/models/connect_device.dart';

class TrustedClientRecord {
  final String clientId;
  final String clientName;
  final String token;
  final int pairedAtMs;

  const TrustedClientRecord({
    required this.clientId,
    required this.clientName,
    required this.token,
    required this.pairedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'clientName': clientName,
        'token': token,
        'pairedAtMs': pairedAtMs,
      };

  factory TrustedClientRecord.fromJson(Map<String, dynamic> json) {
    return TrustedClientRecord(
      clientId: json['clientId'] as String? ?? 'unknown',
      clientName: json['clientName'] as String? ?? 'Phone Controller',
      token: json['token'] as String? ?? '',
      pairedAtMs: (json['pairedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

final connectPairedDevicesStoreProvider =
    Provider<ConnectPairedDevicesStore>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return ConnectPairedDevicesStore(prefs);
});

class ConnectPairedDevicesStore {
  static const String _kLocalDeviceIdKey = 'connect_local_device_id';
  static const String _kLocalDeviceNameKey = 'connect_local_device_name';
  static const String _kHostEnabledKey = 'connect_host_enabled';
  static const String _kPairingPinKey = 'connect_pairing_pin';
  static const String _kQrSessionTokenKey = 'connect_qr_session_token';
  static const String _kTrustedClientsKey = 'connect_trusted_clients_v1';
  static const String _kPairedHostsKey = 'connect_paired_hosts_v1';

  final SharedPreferences _prefs;

  ConnectPairedDevicesStore(this._prefs);

  String get localDeviceId {
    final existing = _prefs.getString(_kLocalDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = 'res_${_generateHex(8)}';
    _prefs.setString(_kLocalDeviceIdKey, generated);
    return generated;
  }

  String get localDeviceName {
    final existing = _prefs.getString(_kLocalDeviceNameKey);
    if (existing != null && existing.isNotEmpty) return existing;
    String fallback;
    try {
      final host = Platform.localHostname.trim();
      fallback = host.isNotEmpty
          ? host
          : (Platform.isAndroid ? 'Android Phone' : 'Desktop PC');
    } catch (_) {
      fallback = Platform.isAndroid ? 'Android Phone' : 'Desktop PC';
    }
    _prefs.setString(_kLocalDeviceNameKey, fallback);
    return fallback;
  }

  Future<void> setLocalDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _prefs.setString(_kLocalDeviceNameKey, trimmed);
  }

  bool get isHostEnabled {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return _prefs.getBool(_kHostEnabledKey) ?? isDesktop;
  }

  Future<void> setHostEnabled(bool enabled) async {
    await _prefs.setBool(_kHostEnabledKey, enabled);
  }

  String get pairingPin {
    final existing = _prefs.getString(_kPairingPinKey);
    if (existing != null && existing.length == 4) return existing;
    return regeneratePairingPin();
  }

  String regeneratePairingPin() {
    final rng = Random.secure();
    final pin = (1000 + rng.nextInt(9000)).toString();
    _prefs.setString(_kPairingPinKey, pin);
    return pin;
  }

  String get qrSessionToken {
    final existing = _prefs.getString(_kQrSessionTokenKey);
    if (existing != null && existing.length >= 16) return existing;
    return regenerateQrSessionToken();
  }

  String regenerateQrSessionToken() {
    final token = _generateHex(24);
    _prefs.setString(_kQrSessionTokenKey, token);
    return token;
  }

  List<TrustedClientRecord> getTrustedClients() {
    final raw = _prefs.getString(_kTrustedClientsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => TrustedClientRecord.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  bool isClientTokenTrusted(String token) {
    if (token.isEmpty) return false;
    if (token == qrSessionToken) return true;
    final clients = getTrustedClients();
    return clients.any((c) => c.token == token);
  }

  Future<TrustedClientRecord> registerTrustedClient({
    required String clientId,
    required String clientName,
  }) async {
    final clients = List<TrustedClientRecord>.from(getTrustedClients());
    final existingIndex = clients.indexWhere((c) => c.clientId == clientId);
    final token = (existingIndex >= 0 && clients[existingIndex].token.isNotEmpty)
        ? clients[existingIndex].token
        : _generateClientAuthToken(clientId);
    final record = TrustedClientRecord(
      clientId: clientId,
      clientName: clientName,
      token: token,
      pairedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (existingIndex >= 0) {
      clients[existingIndex] = record;
    } else {
      clients.add(record);
    }
    await _saveTrustedClients(clients);
    return record;
  }

  Future<void> revokeTrustedClient(String clientId) async {
    final clients = getTrustedClients()
        .where((c) => c.clientId != clientId)
        .toList();
    await _saveTrustedClients(clients);
  }

  Future<void> _saveTrustedClients(List<TrustedClientRecord> clients) async {
    final encoded = jsonEncode(clients.map((c) => c.toJson()).toList());
    await _prefs.setString(_kTrustedClientsKey, encoded);
  }

  List<ConnectDevice> getPairedHosts() {
    final raw = _prefs.getString(_kPairedHostsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => ConnectDevice.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  ConnectDevice? getPairedHostById(String hostId) {
    for (final host in getPairedHosts()) {
      if (host.id == hostId) return host;
    }
    return null;
  }

  Future<void> savePairedHost(ConnectDevice device) async {
    final hosts = List<ConnectDevice>.from(getPairedHosts());
    final idx = hosts.indexWhere(
      (h) => h.id == device.id || (h.ip == device.ip && h.port == device.port),
    );
    final updated = device.copyWith(
      isPaired: true,
      lastSeen: DateTime.now(),
    );
    if (idx >= 0) {
      hosts[idx] = updated;
    } else {
      hosts.add(updated);
    }
    await _prefs.setString(
      _kPairedHostsKey,
      jsonEncode(hosts.map((h) => h.toJson()).toList()),
    );
  }

  Future<void> removePairedHost(String hostId) async {
    final hosts = getPairedHosts().where((h) => h.id != hostId).toList();
    await _prefs.setString(
      _kPairedHostsKey,
      jsonEncode(hosts.map((h) => h.toJson()).toList()),
    );
  }

  String _generateClientAuthToken(String clientId) {
    final raw =
        '$clientId:${DateTime.now().microsecondsSinceEpoch}:${_generateHex(16)}';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  static String _generateHex(int length) {
    final rng = Random.secure();
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)])
        .join();
  }
}

