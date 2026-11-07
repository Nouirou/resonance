import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../domain/models/connect_device.dart';

class ConnectUdpBeacon {
  static const int discoveryPort = 52025;
  static const String _kDiscoverProbe = 'RESONANCE_DISCOVER_V1';
  static const String _kAnnouncePrefix = 'RESONANCE_HOST_V1:';
  static const MethodChannel _androidPlatformChannel =
      MethodChannel('com.chronostudio.resonance/potoken');

  RawDatagramSocket? _hostSocket;

  static List<String>? _cachedLanIps;
  static int _cachedLanIpsEpochMs = 0;
  static const int _lanIpCacheTtlMs = 15000;

  /// Resolves all non-loopback IPv4 LAN addresses, ranked so physical Wi-Fi / Ethernet
  /// adapters come before virtual adapters (WSL, Hyper-V, Docker, VirtualBox, VMware).
  /// Cached for 15 seconds to avoid repeated OS network interface syscalls during discovery bursts.
  static Future<List<String>> resolveLocalLanIps({
    bool forceRefresh = false,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!forceRefresh &&
        _cachedLanIps != null &&
        (nowMs - _cachedLanIpsEpochMs) < _lanIpCacheTtlMs) {
      return _cachedLanIps!;
    }
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final primary = <String>[];
      final secondary = <String>[];

      for (final iface in interfaces) {
        final nameLower = iface.name.toLowerCase();
        final isVirtual = nameLower.contains('vethernet') ||
            nameLower.contains('wsl') ||
            nameLower.contains('docker') ||
            nameLower.contains('vbox') ||
            nameLower.contains('virtualbox') ||
            nameLower.contains('vmware') ||
            nameLower.contains('loopback') ||
            nameLower.contains('tailscale') ||
            nameLower.contains('zero');

        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          if (isVirtual) {
            secondary.add(ip);
          } else {
            primary.add(ip);
          }
        }
      }

      // Sort primary so 192.168.x.x comes first, then 10.x.x.x, then 172.x.x.x
      int scoreIp(String ip) {
        if (ip.startsWith('192.168.')) return 0;
        if (ip.startsWith('10.')) return 1;
        return 2;
      }

      primary.sort((a, b) => scoreIp(a).compareTo(scoreIp(b)));
      final result = List<String>.unmodifiable([...primary, ...secondary]);
      _cachedLanIps = result;
      _cachedLanIpsEpochMs = nowMs;
      return result;
    } catch (_) {
      return _cachedLanIps ?? const [];
    }
  }

  static Future<String> resolvePrimaryLanIp({bool forceRefresh = false}) async {
    final ips = await resolveLocalLanIps(forceRefresh: forceRefresh);
    return ips.isNotEmpty ? ips.first : '127.0.0.1';
  }

  /// Picks the local IPv4 on the same /24 subnet as [remoteIp], or falls back to primary.
  static Future<String> resolveBestLocalIpForPeer(String remoteIp) async {
    final ips = await resolveLocalLanIps();
    if (ips.isEmpty) return '127.0.0.1';
    final parts = remoteIp.split('.');
    if (parts.length == 4) {
      final prefix3 = '${parts[0]}.${parts[1]}.${parts[2]}.';
      for (final ip in ips) {
        if (ip.startsWith(prefix3)) return ip;
      }
      final prefix2 = '${parts[0]}.${parts[1]}.';
      for (final ip in ips) {
        if (ip.startsWith(prefix2)) return ip;
      }
    }
    return ips.first;
  }

  static Future<void> setAndroidMulticastLock(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _androidPlatformChannel.invokeMethod(
        'setMulticastLock',
        {'active': active},
      );
    } catch (_) {}
  }

  /// Starts UDP discovery responder on the Desktop Host.
  Future<void> startHostResponder({
    required String hostId,
    required String hostName,
    required int wsPort,
  }) async {
    await stopHostResponder();
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _hostSocket = socket;

      socket.listen((RawSocketEvent event) async {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;

        try {
          final msg = utf8.decode(dg.data, allowMalformed: true).trim();
          if (msg.startsWith(_kDiscoverProbe)) {
            final peerIp = dg.address.address;
            final bestLocalIp = await resolveBestLocalIpForPeer(peerIp);
            final responsePayload = '$_kAnnouncePrefix${jsonEncode({
              'id': hostId,
              'name': hostName,
              'ip': bestLocalIp,
              'port': wsPort,
              'version': '1.0.0',
            })}';
            final bytes = utf8.encode(responsePayload);
            socket.send(bytes, dg.address, dg.port);
          }
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('[Connect] UDP host bind error: $e');
    }
  }

  Future<void> stopHostResponder() async {
    _hostSocket?.close();
    _hostSocket = null;
  }

  /// Broadcasts UDP discovery probes across local subnets and collects responding Desktop Hosts.
  Future<void> scanForHosts({
    required void Function(ConnectDevice device) onDeviceFound,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await setAndroidMulticastLock(true);
    RawDatagramSocket? clientSocket;
    try {
      clientSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      clientSocket.broadcastEnabled = true;

      clientSocket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final dg = clientSocket?.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true).trim();
        if (text.startsWith(_kAnnouncePrefix)) {
          final jsonStr = text.substring(_kAnnouncePrefix.length);
          try {
            final map = jsonDecode(jsonStr) as Map<String, dynamic>;
            final advertisedIp = map['ip'] as String?;
            final ip = (advertisedIp != null &&
                    advertisedIp.isNotEmpty &&
                    advertisedIp != '127.0.0.1')
                ? advertisedIp
                : dg.address.address;
            final device = ConnectDevice(
              id: map['id'] as String? ?? 'host_$ip',
              name: map['name'] as String? ?? 'Desktop PC',
              ip: ip,
              port: (map['port'] as num?)?.toInt() ?? 52026,
              version: map['version'] as String? ?? '1.0.0',
              discoveryMethod: ConnectDiscoveryMethod.udpBeacon,
              lastSeen: DateTime.now(),
            );
            onDeviceFound(device);
          } catch (_) {}
        }
      });

      final targets = await _buildBroadcastTargets();
      final probeBytes = utf8.encode(_kDiscoverProbe);

      // Fire 3 rapid bursts across broadcast addresses to overcome UDP packet loss
      for (int attempt = 0; attempt < 3; attempt++) {
        for (final target in targets) {
          try {
            clientSocket.send(
              probeBytes,
              InternetAddress(target),
              discoveryPort,
            );
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 450));
      }

      final remaining = timeout - const Duration(milliseconds: 1350);
      if (remaining > Duration.zero) {
        await Future.delayed(remaining);
      }
    } catch (e) {
      debugPrint('[Connect] UDP client scan error: $e');
    } finally {
      clientSocket?.close();
      await setAndroidMulticastLock(false);
    }
  }

  static Future<Set<String>> _buildBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    final localIps = await resolveLocalLanIps();
    for (final ip in localIps) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
      }
    }
    return targets;
  }
}

