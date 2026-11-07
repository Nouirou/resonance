import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/connect_device.dart';
import '../infrastructure/client/connect_socket_client.dart';
import '../infrastructure/discovery/connect_mdns_discovery.dart';
import '../infrastructure/discovery/connect_udp_beacon.dart';
import '../infrastructure/storage/connect_paired_devices_store.dart';

class ConnectDiscoveryState {
  final List<ConnectDevice> availableDevices;
  final bool isScanning;

  const ConnectDiscoveryState({
    this.availableDevices = const [],
    this.isScanning = false,
  });

  ConnectDiscoveryState copyWith({
    List<ConnectDevice>? availableDevices,
    bool? isScanning,
  }) {
    return ConnectDiscoveryState(
      availableDevices: availableDevices ?? this.availableDevices,
      isScanning: isScanning ?? this.isScanning,
    );
  }
}

final connectDiscoveryProvider =
    NotifierProvider<ConnectDiscoveryNotifier, ConnectDiscoveryState>(
  ConnectDiscoveryNotifier.new,
);

class ConnectDiscoveryNotifier extends Notifier<ConnectDiscoveryState> {
  final ConnectMdnsDiscovery _mdns = ConnectMdnsDiscovery();
  final ConnectUdpBeacon _udp = ConnectUdpBeacon();
  final Map<String, ConnectDevice> _deviceMap = {};

  @override
  ConnectDiscoveryState build() {
    final store = ref.watch(connectPairedDevicesStoreProvider);

    ref.onDispose(() {
      _mdns.stopBrowsing();
    });

    // Seed with saved paired hosts
    _deviceMap.clear();
    for (final paired in store.getPairedHosts()) {
      if (paired.id != store.localDeviceId) {
        _deviceMap[paired.id] = paired;
      }
    }

    return ConnectDiscoveryState(
      availableDevices: _sortedDevices(),
      isScanning: false,
    );
  }

  /// Runs a comprehensive discovery sweep combining:
  /// 1. Direct HTTP `/info?token=...` reachability & token-validity probes on previously paired hosts
  /// 2. mDNS / Zeroconf browsing (`_resonance-rc._tcp`)
  /// 3. Subnet UDP broadcast beacons (`255.255.255.255:52025`)
  Future<void> startScan() async {
    if (state.isScanning) return;
    final store = ref.read(connectPairedDevicesStoreProvider);
    final selfId = store.localDeviceId;

    state = state.copyWith(isScanning: true);

    try {
      // 1. Probe saved paired hosts in parallel and verify their saved token is still trusted on the Host
      final savedHosts = store.getPairedHosts();
      unawaited(
        Future.wait(
          savedHosts.map((host) async {
            if (host.id == selfId) return;
            final live = await ConnectSocketClient.probeHost(
              ip: host.ip,
              port: host.port,
              savedAuthToken: host.authToken,
              method: ConnectDiscoveryMethod.pairedHistory,
            );
            if (live != null) {
              if (!live.isPaired) {
                // Host revoked our token while we were offline -> remove stale paired record
                await store.removePairedHost(host.id);
              }
              _deviceMap[live.id] = live;
              state = state.copyWith(availableDevices: _sortedDevices());
            }
          }),
        ),
      );

      // 2. Start mDNS browsing
      unawaited(
        _mdns.startBrowsing(
          onDeviceFound: (device) {
            if (device.id == selfId) return;
            _upsertDiscoveredDevice(device);
          },
          onDeviceLost: (_) {},
        ),
      );

      // 3. Broadcast UDP discovery probes (waits ~3s)
      await _udp.scanForHosts(
        onDeviceFound: (device) {
          if (device.id == selfId) return;
          _upsertDiscoveredDevice(device);
        },
        timeout: const Duration(seconds: 3),
      );
    } finally {
      await _mdns.stopBrowsing();
      state = state.copyWith(
        isScanning: false,
        availableDevices: _sortedDevices(),
      );
    }
  }

  /// Stops active mDNS browsing and releases Android Wi-Fi MulticastLock immediately
  /// if the user dismisses the discovery sheet early.
  Future<void> stopScan() async {
    await _mdns.stopBrowsing();
    if (state.isScanning) {
      state = state.copyWith(isScanning: false);
    }
  }

  Future<void> _upsertDiscoveredDevice(ConnectDevice incoming) async {
    final store = ref.read(connectPairedDevicesStoreProvider);
    if (incoming.id == store.localDeviceId) return;

    final existingPaired = store.getPairedHostById(incoming.id);
    if (existingPaired != null &&
        existingPaired.authToken != null &&
        existingPaired.authToken!.isNotEmpty) {
      // Verify with host /info whether existingPaired.authToken is still trusted
      final verified = await ConnectSocketClient.probeHost(
        ip: incoming.ip,
        port: incoming.port,
        savedAuthToken: existingPaired.authToken,
        method: incoming.discoveryMethod,
      );
      if (verified != null) {
        if (!verified.isPaired) {
          await store.removePairedHost(incoming.id);
        } else {
          // Keep IP updated in store if DHCP changed it
          await store.savePairedHost(verified);
        }
        _deviceMap[verified.id] = verified;
        state = state.copyWith(availableDevices: _sortedDevices());
        return;
      }
    }

    _deviceMap[incoming.id] = incoming;
    state = state.copyWith(availableDevices: _sortedDevices());
  }

  /// Forgets a paired Desktop Host locally AND sends `POST /unpair` to the Desktop Host
  /// so the Desktop Host also removes this phone from `Remembered Mobile Remotes`.
  Future<void> removePairedDevice(String hostId) async {
    final store = ref.read(connectPairedDevicesStoreProvider);
    final existing = _deviceMap[hostId] ?? store.getPairedHostById(hostId);
    if (existing != null) {
      unawaited(
        ConnectSocketClient.unpairFromHost(
          device: existing,
          clientId: store.localDeviceId,
        ),
      );
    }
    await store.removePairedHost(hostId);
    if (existing != null) {
      if (existing.discoveryMethod == ConnectDiscoveryMethod.pairedHistory) {
        _deviceMap.remove(hostId);
      } else {
        _deviceMap[hostId] = existing.copyWith(
          isPaired: false,
          clearAuthToken: true,
        );
      }
    }
    state = state.copyWith(availableDevices: _sortedDevices());
  }

  /// Downgrades a device to unpaired in-memory and in disk storage (used when token is revoked).
  Future<void> markDeviceUnpaired(String hostId) async {
    final store = ref.read(connectPairedDevicesStoreProvider);
    await store.removePairedHost(hostId);
    final existing = _deviceMap[hostId];
    if (existing != null) {
      _deviceMap[hostId] = existing.copyWith(
        isPaired: false,
        clearAuthToken: true,
      );
      state = state.copyWith(availableDevices: _sortedDevices());
    }
  }

  void upsertPairedDevice(ConnectDevice device) {
    _deviceMap[device.id] = device;
    state = state.copyWith(availableDevices: _sortedDevices());
  }

  List<ConnectDevice> _sortedDevices() {
    final list = _deviceMap.values.toList();
    list.sort((a, b) {
      if (a.isPaired != b.isPaired) {
        return a.isPaired ? -1 : 1;
      }
      return b.lastSeen.compareTo(a.lastSeen);
    });
    return list;
  }
}
