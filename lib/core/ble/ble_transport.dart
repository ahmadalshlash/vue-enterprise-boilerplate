import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:flutter/foundation.dart';

import '../crypto/eid.dart';
import '../protocol/chunker.dart';
import '../protocol/constants.dart';
import 'transport.dart';

/// Produktiver Transport über Bluetooth Low Energy.
///
/// Jedes Gerät ist gleichzeitig
/// * **Central**: scannt nach der Service-UUID, verbindet sich, liest
///   Presence/Profil/Board und schreibt Frames in die Inbox des Peers;
///   empfängt Antworten als Notifications auf der Outbox des Peers.
/// * **Peripheral**: sendet Advertising, beantwortet Lesezugriffe aus den
///   [TransportProviders], nimmt Frames auf der Inbox an und antwortet
///   über Notifications auf der eigenen Outbox.
///
/// Siehe konzept/protokoll.md Abschnitte 1, 3 und 5.1.
class BleTransport implements NearbyTransport {
  BleTransport({ble.CentralManager? central, ble.PeripheralManager? peripheral})
      : _central = central ?? ble.CentralManager(),
        _peripheral = peripheral ?? ble.PeripheralManager();

  final ble.CentralManager _central;
  final ble.PeripheralManager _peripheral;

  static final _serviceUuid = ble.UUID.fromString(ProtocolConstants.serviceUuid);
  static final _presenceUuid = ble.UUID.fromString(ProtocolConstants.presenceUuid);
  static final _inboxUuid = ble.UUID.fromString(ProtocolConstants.inboxUuid);
  static final _outboxUuid = ble.UUID.fromString(ProtocolConstants.outboxUuid);
  static final _profileUuid = ble.UUID.fromString(ProtocolConstants.profileUuid);
  static final _boardUuid = ble.UUID.fromString(ProtocolConstants.boardUuid);

  static const int _maxLinks = 6;
  static const Duration _idleTimeout = Duration(seconds: 10);

  final _sightings = StreamController<Sighting>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();
  final _status = StreamController<TransportStatus>.broadcast();
  TransportProviders _providers = TransportProviders(
    presence: () => Uint8List(0),
    profile: () => Uint8List(0),
    board: () => Uint8List(0),
  );

  final List<StreamSubscription> _subs = [];
  final Map<String, _PeripheralLink> _links = {};
  final Map<String, _CentralLink> _centrals = {};
  late final ble.GATTCharacteristic _outboxChar;
  bool _started = false;
  bool _advertising = false;
  bool _serviceAdded = false;

  @override
  Stream<Sighting> get sightings => _sightings.stream;
  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Stream<TransportStatus> get statusChanges => _status.stream;

  @override
  TransportStatus get status => _mapState(_central.state);

  @override
  void setProviders(TransportProviders providers) => _providers = providers;

  // ---------------------------------------------------------------- Start/Stop

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _subs.add(_central.stateChanged.listen((e) async {
      _status.add(_mapState(e.state));
      if (e.state == ble.BluetoothLowEnergyState.unauthorized &&
          defaultTargetPlatform == TargetPlatform.android) {
        await _central.authorize();
      }
      if (e.state == ble.BluetoothLowEnergyState.poweredOn) {
        await _startScanning();
      }
    }));
    _subs.add(_central.discovered.listen(_onDiscovered));
    _subs.add(_central.connectionStateChanged.listen((e) {
      if (e.state == ble.ConnectionState.disconnected) {
        _links.remove(e.peripheral.uuid.toString())?.dispose();
      }
    }));
    _subs.add(_central.characteristicNotified.listen(_onNotified));

    _subs.add(_peripheral.characteristicReadRequested.listen(_onReadRequested));
    _subs.add(_peripheral.characteristicWriteRequested.listen(_onWriteRequested));
    _subs.add(_peripheral.characteristicNotifyStateChanged.listen((e) {
      final id = e.central.uuid.toString();
      if (e.state) {
        (_centrals[id] ??= _CentralLink(e.central)).notifying = true;
      } else {
        _centrals[id]?.notifying = false;
      }
    }));
    _subs.add(_peripheral.connectionStateChanged.listen((e) {
      if (e.state == ble.ConnectionState.disconnected) {
        _centrals.remove(e.central.uuid.toString());
      }
    }));

    if (_central.state == ble.BluetoothLowEnergyState.unauthorized &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _central.authorize();
    }
    if (_central.state == ble.BluetoothLowEnergyState.poweredOn) {
      await _startScanning();
    }
    await _ensureService();
  }

  Future<void> _startScanning() async {
    try {
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
    } catch (e) {
      debugPrint('BLE: startDiscovery fehlgeschlagen: $e');
    }
  }

  Future<void> _ensureService() async {
    if (_serviceAdded) return;
    if (_peripheral.state != ble.BluetoothLowEnergyState.poweredOn) return;
    _outboxChar = ble.GATTCharacteristic.mutable(
      uuid: _outboxUuid,
      properties: [ble.GATTCharacteristicProperty.notify],
      permissions: [ble.GATTCharacteristicPermission.read],
      descriptors: [],
    );
    final service = ble.GATTService(
      uuid: _serviceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [
        _readable(_presenceUuid),
        ble.GATTCharacteristic.mutable(
          uuid: _inboxUuid,
          properties: [ble.GATTCharacteristicProperty.write],
          permissions: [ble.GATTCharacteristicPermission.write],
          descriptors: [],
        ),
        _outboxChar,
        _readable(_profileUuid),
        _readable(_boardUuid),
      ],
    );
    try {
      await _peripheral.removeAllServices();
      await _peripheral.addService(service);
      _serviceAdded = true;
    } catch (e) {
      debugPrint('BLE: addService fehlgeschlagen: $e');
    }
  }

  static ble.GATTCharacteristic _readable(ble.UUID uuid) => ble.GATTCharacteristic.mutable(
        uuid: uuid,
        properties: [ble.GATTCharacteristicProperty.read],
        permissions: [ble.GATTCharacteristicPermission.read],
        descriptors: [],
      );

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    await setAdvertising(null);
    for (final link in _links.values) {
      link.dispose();
      try {
        await _central.disconnect(link.peripheral);
      } catch (_) {}
    }
    _links.clear();
    _centrals.clear();
  }

  @override
  Future<void> setAdvertising(Uint8List? eid) async {
    if (eid == null) {
      if (_advertising) {
        try {
          await _peripheral.stopAdvertising();
        } catch (_) {}
        _advertising = false;
      }
      return;
    }
    await _ensureService();
    if (_peripheral.state != ble.BluetoothLowEnergyState.poweredOn) return;
    if (_advertising) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
    }
    try {
      await _peripheral.startAdvertising(
        ble.Advertisement(
          name: Eid.toAdvertisingName(eid),
          serviceUUIDs: [_serviceUuid],
        ),
      );
      _advertising = true;
    } catch (e) {
      _advertising = false;
      throw TransportException('Advertising konnte nicht gestartet werden', e);
    }
  }

  // ------------------------------------------------------------- Central-Seite

  void _onDiscovered(ble.DiscoveredEventArgs e) {
    final adv = e.advertisement;
    final matches = adv.serviceUUIDs.any((u) => u == _serviceUuid || u.toString() == _serviceUuid.toString());
    final eid = Eid.fromAdvertisingName(adv.name);
    if (!matches && eid == null) return;
    final id = 'p:${e.peripheral.uuid}';
    _knownPeripherals[e.peripheral.uuid.toString()] = e.peripheral;
    _sightings.add(Sighting(
      peerId: id,
      eid: eid ?? Uint8List(0),
      rssi: e.rssi,
      at: DateTime.now(),
    ));
  }

  final Map<String, ble.Peripheral> _knownPeripherals = {};

  Future<_PeripheralLink> _link(PeerId peer) async {
    if (!peer.startsWith('p:')) {
      throw TransportException('Kein Peripheral: $peer');
    }
    final uuid = peer.substring(2);
    final existing = _links[uuid];
    if (existing != null && existing.ready) {
      existing.touch(() => _disconnect(uuid));
      return existing;
    }
    final peripheral = _knownPeripherals[uuid];
    if (peripheral == null) {
      throw TransportException('Peer nicht (mehr) bekannt: $peer');
    }
    await _evictIfNeeded();
    final link = _links[uuid] ??= _PeripheralLink(peripheral);
    await link.lock(() async {
      if (link.ready) return;
      try {
        await _central.connect(peripheral);
        try {
          link.mtu = await _central.requestMTU(peripheral, mtu: ProtocolConstants.preferredMtu);
        } catch (_) {
          link.mtu = ProtocolConstants.minimumMtu;
        }
        final services = await _central.discoverGATT(peripheral);
        final svc = services.where((s) => s.uuid.toString() == _serviceUuid.toString()).firstOrNull;
        if (svc == null) {
          throw const TransportException('Peer bietet den Umkreis-Dienst nicht an');
        }
        for (final c in svc.characteristics) {
          link.chars[c.uuid.toString()] = c;
        }
        final outbox = link.chars[_outboxUuid.toString()];
        if (outbox != null) {
          await _central.setCharacteristicNotifyState(peripheral, outbox, state: true);
        }
        link.writeLength = await _central.getMaximumWriteLength(
          peripheral,
          type: ble.GATTCharacteristicWriteType.withResponse,
        );
        link.ready = true;
      } catch (e) {
        _links.remove(uuid);
        try {
          await _central.disconnect(peripheral);
        } catch (_) {}
        if (e is TransportException) rethrow;
        throw TransportException('Verbindung fehlgeschlagen', e);
      }
    });
    link.touch(() => _disconnect(uuid));
    return link;
  }

  Future<void> _evictIfNeeded() async {
    if (_links.length < _maxLinks) return;
    final oldest = _links.entries.reduce((a, b) => a.value.lastUsed.isBefore(b.value.lastUsed) ? a : b);
    await _disconnect(oldest.key);
  }

  Future<void> _disconnect(String uuid) async {
    final link = _links.remove(uuid);
    if (link == null) return;
    link.dispose();
    try {
      await _central.disconnect(link.peripheral);
    } catch (_) {}
  }

  @override
  Future<Uint8List> read(PeerId peer, ReadTarget target) async {
    if (peer.startsWith('c:')) {
      // Ein Central, das mit uns verbunden ist, bietet uns keinen Dienst an.
      throw const TransportException('Lesen nur von Peripherals möglich');
    }
    final link = await _link(peer);
    final uuid = switch (target) {
      ReadTarget.presence => _presenceUuid,
      ReadTarget.profile => _profileUuid,
      ReadTarget.board => _boardUuid,
    };
    final c = link.chars[uuid.toString()];
    if (c == null) throw TransportException('Characteristic fehlt: $target');
    return link.lock(() async {
      try {
        return await _central.readCharacteristic(link.peripheral, c);
      } catch (e) {
        throw TransportException('Lesen fehlgeschlagen', e);
      }
    });
  }

  @override
  Future<void> send(PeerId peer, Uint8List frameBytes) async {
    if (peer.startsWith('c:')) {
      return _notifyCentral(peer.substring(2), frameBytes);
    }
    final link = await _link(peer);
    final inbox = link.chars[_inboxUuid.toString()];
    if (inbox == null) throw const TransportException('Inbox fehlt');
    final chunkSize = link.writeLength.clamp(Chunker.headerLength + 1, 512);
    final chunks = link.chunker.split(frameBytes, chunkSize);
    await link.lock(() async {
      for (final chunk in chunks) {
        try {
          await _central.writeCharacteristic(
            link.peripheral,
            inbox,
            value: chunk,
            type: ble.GATTCharacteristicWriteType.withResponse,
          );
        } catch (e) {
          throw TransportException('Senden fehlgeschlagen', e);
        }
      }
    });
  }

  void _onNotified(ble.GATTCharacteristicNotifiedEventArgs e) {
    if (e.characteristic.uuid.toString() != _outboxUuid.toString()) return;
    final uuid = e.peripheral.uuid.toString();
    final link = _links[uuid];
    if (link == null) return;
    final frame = link.reassembler.accept(e.value);
    if (frame != null) _inbound.add(InboundFrame('p:$uuid', frame));
  }

  // ---------------------------------------------------------- Peripheral-Seite

  Future<void> _onReadRequested(ble.GATTCharacteristicReadRequestedEventArgs e) async {
    final uuid = e.characteristic.uuid.toString();
    Uint8List value;
    if (uuid == _presenceUuid.toString()) {
      value = _providers.presence();
    } else if (uuid == _profileUuid.toString()) {
      value = _providers.profile();
    } else if (uuid == _boardUuid.toString()) {
      value = _providers.board();
    } else {
      await _peripheral.respondReadRequestWithError(e.request, error: ble.GATTError.readNotPermitted);
      return;
    }
    final offset = e.request.offset.clamp(0, value.length);
    await _peripheral.respondReadRequestWithValue(e.request, value: value.sublist(offset));
  }

  Future<void> _onWriteRequested(ble.GATTCharacteristicWriteRequestedEventArgs e) async {
    if (e.characteristic.uuid.toString() != _inboxUuid.toString()) {
      await _peripheral.respondWriteRequestWithError(e.request, error: ble.GATTError.writeNotPermitted);
      return;
    }
    final id = e.central.uuid.toString();
    final link = _centrals[id] ??= _CentralLink(e.central);
    link.central = e.central;
    await _peripheral.respondWriteRequest(e.request);
    final frame = link.reassembler.accept(e.request.value);
    if (frame != null) _inbound.add(InboundFrame('c:$id', frame));
  }

  Future<void> _notifyCentral(String id, Uint8List frameBytes) async {
    final link = _centrals[id];
    if (link == null) throw const TransportException('Central nicht (mehr) verbunden');
    int maxLen;
    try {
      maxLen = await _peripheral.getMaximumNotifyLength(link.central);
    } catch (_) {
      maxLen = ProtocolConstants.minimumMtu - 3;
    }
    final chunks = link.chunker.split(frameBytes, maxLen.clamp(Chunker.headerLength + 1, 512));
    for (final chunk in chunks) {
      try {
        await _peripheral.notifyCharacteristic(link.central, _outboxChar, value: chunk);
      } catch (e) {
        throw TransportException('Notify fehlgeschlagen', e);
      }
    }
  }

  @override
  Future<void> drop(PeerId peer) async {
    if (peer.startsWith('p:')) {
      await _disconnect(peer.substring(2));
    } else if (peer.startsWith('c:')) {
      final link = _centrals.remove(peer.substring(2));
      if (link != null) {
        try {
          await _peripheral.disconnect(link.central);
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _sightings.close();
    await _inbound.close();
    await _status.close();
  }

  static TransportStatus _mapState(ble.BluetoothLowEnergyState s) => switch (s) {
        ble.BluetoothLowEnergyState.unknown => TransportStatus.unknown,
        ble.BluetoothLowEnergyState.unsupported => TransportStatus.unsupported,
        ble.BluetoothLowEnergyState.unauthorized => TransportStatus.unauthorized,
        ble.BluetoothLowEnergyState.poweredOff => TransportStatus.poweredOff,
        ble.BluetoothLowEnergyState.poweredOn => TransportStatus.ready,
      };
}

/// Verbindung zu einem Peripheral (wir sind Central).
class _PeripheralLink {
  _PeripheralLink(this.peripheral);

  final ble.Peripheral peripheral;
  final Map<String, ble.GATTCharacteristic> chars = {};
  final Chunker chunker = Chunker();
  final Reassembler reassembler = Reassembler();
  int mtu = ProtocolConstants.minimumMtu;
  int writeLength = ProtocolConstants.minimumMtu - 3;
  bool ready = false;
  DateTime lastUsed = DateTime.now();
  Timer? _idle;
  Future<void> _queue = Future.value();

  /// Serialisiert alle GATT-Operationen auf dieser Verbindung.
  Future<T> lock<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  void touch(Future<void> Function() onIdle) {
    lastUsed = DateTime.now();
    _idle?.cancel();
    _idle = Timer(BleTransport._idleTimeout, onIdle);
  }

  void dispose() {
    _idle?.cancel();
    ready = false;
  }
}

/// Ein Central, das mit uns verbunden ist (wir sind Peripheral).
class _CentralLink {
  _CentralLink(this.central);
  ble.Central central;
  bool notifying = false;
  final Chunker chunker = Chunker();
  final Reassembler reassembler = Reassembler();
}
