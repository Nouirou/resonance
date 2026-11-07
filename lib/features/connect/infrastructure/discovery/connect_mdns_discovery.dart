import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import '../../domain/models/connect_device.dart';
import 'connect_udp_beacon.dart';

class ConnectMdnsDiscovery {
  /// RFC 6335 Section 5.1 requires service names to be <= 15 characters (excluding `_` and `._tcp`).
  /// `_resonance-rc._tcp` is 12 characters (`resonance-rc`), 100% RFC-compliant.
  static const String serviceType = '_resonance-rc._tcp';

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _discoverySub;

  /// Starts advertising the Desktop Host over mDNS / Zeroconf.
  Future<void> startAdvertising({
    required String hostId,
    required String hostName,
    required int port,
  }) async {
    await stopAdvertising();
    try {
      final localIp = await ConnectUdpBeacon.resolvePrimaryLanIp();
      final service = BonsoirService(
        name: 'Resonance-$hostName',
        type: serviceType,
        port: port,
        attributes: {
          'id': hostId,
          'name': hostName,
          'ip': localIp,
          'version': '1.0.0',
        },
      );
      final broadcast = BonsoirBroadcast(
        service: service,
        printLogs: false,
      );
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
      debugPrint(
        '[Connect] mDNS advertising $serviceType on $localIp:$port',
      );
    } catch (e) {
      debugPrint('[Connect] mDNS broadcast warning: $e');
    }
  }

  Future<void> stopAdvertising() async {
    final b = _broadcast;
    _broadcast = null;
    if (b != null) {
      try {
        await b.stop();
      } catch (_) {}
    }
  }

  /// Starts browsing for `_resonance-rc._tcp` services over mDNS.
  Future<void> startBrowsing({
    required void Function(ConnectDevice device) onDeviceFound,
    required void Function(String hostId) onDeviceLost,
  }) async {
    await stopBrowsing();
    await ConnectUdpBeacon.setAndroidMulticastLock(true);
    try {
      final discovery = BonsoirDiscovery(
        type: serviceType,
        printLogs: false,
      );
      await discovery.initialize();
      _discovery = discovery;

      _discoverySub = discovery.eventStream?.listen((event) {
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          event.service.resolve(discovery.serviceResolver);
        } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final srv = event.service;
          final attrs = srv.attributes;
          final hostFromSrv = srv.toJson()['service.host'] as String?;
          final ipFromAttr = attrs['ip'];
          final resolvedIp =
              (ipFromAttr != null && ipFromAttr.isNotEmpty)
                  ? ipFromAttr
                  : (hostFromSrv ?? '');
          if (resolvedIp.isEmpty) return;

          final device = ConnectDevice(
            id: attrs['id'] ?? 'mdns_${srv.name}',
            name: attrs['name'] ?? srv.name.replaceFirst('Resonance-', ''),
            ip: resolvedIp,
            port: srv.port,
            version: attrs['version'] ?? '1.0.0',
            discoveryMethod: ConnectDiscoveryMethod.mdns,
            lastSeen: DateTime.now(),
          );
          onDeviceFound(device);
        } else if (event is BonsoirDiscoveryServiceLostEvent) {
          final id = event.service.attributes['id'] ??
              'mdns_${event.service.name}';
          onDeviceLost(id);
        }
      });

      await discovery.start();
    } catch (e) {
      debugPrint('[Connect] mDNS browse warning: $e');
    }
  }

  Future<void> stopBrowsing() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      try {
        await d.stop();
      } catch (_) {}
    }
    await ConnectUdpBeacon.setAndroidMulticastLock(false);
  }
}
