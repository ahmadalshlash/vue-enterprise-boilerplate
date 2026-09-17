import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../protocol/chunker.dart';
import 'transport.dart';

/// Simulierte Funkwelt: mehrere [FakeTransport]s mit Positionen in Metern.
/// RSSI wird aus der Distanz berechnet, Frames werden gechunkt und
/// wieder zusammengesetzt, damit derselbe Codepfad wie bei BLE läuft.
class FakeWorld {
  FakeWorld({
    this.tick = const Duration(seconds: 1),
    this.maxRangeMeters = 100,
    this.fakeMtu = 100,
    this.latency = Duration.zero,
    Random? random,
  }) : _random = random ?? Random(42);

  final Duration tick;
  final double maxRangeMeters;
  final int fakeMtu;
  final Duration latency;
  final Random _random;
  final Map<String, FakeTransport> _nodes = {};
  Timer? _timer;

  FakeTransport createNode(String id, {double x = 0, double y = 0}) {
    final node = FakeTransport._(this, id, x, y);
    _nodes[id] = node;
    return node;
  }

  void remove(String id) => _nodes.remove(id);

  void moveTo(String id, double x, double y) {
    final n = _nodes[id];
    if (n == null) return;
    n.x = x;
    n.y = y;
  }

  /// Startet den periodischen Advertising-Tick.
  void start() {
    _timer ??= Timer.periodic(tick, (_) => broadcast());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ein Advertising-Zyklus: jeder sichtbare Knoten wird von allen anderen
  /// in Reichweite gesehen.
  void broadcast() {
    final now = DateTime.now();
    for (final sender in _nodes.values) {
      final eid = sender._eid;
      if (eid == null || !sender._started) continue;
      for (final receiver in _nodes.values) {
        if (identical(sender, receiver) || !receiver._started) continue;
        final d = _distance(sender, receiver);
        if (d > maxRangeMeters) continue;
        receiver._sightings.add(Sighting(
          peerId: 'f:${sender.id}',
          eid: eid,
          rssi: rssiFor(d),
          at: now,
        ));
      }
    }
  }

  /// Log-Distance-Modell mit leichtem Rauschen: ~ -45 dBm bei 1 m.
  int rssiFor(double meters) {
    final d = max(meters, 0.5);
    final base = -45 - 10 * 2.7 * (log(d) / ln10);
    return (base + (_random.nextDouble() * 6 - 3)).round();
  }

  double _distance(FakeTransport a, FakeTransport b) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

  FakeTransport? _node(String id) => _nodes[id];
}

/// Transport innerhalb einer [FakeWorld].
class FakeTransport implements NearbyTransport {
  FakeTransport._(this._world, this.id, this.x, this.y);

  final FakeWorld _world;
  final String id;
  double x;
  double y;

  final _sightings = StreamController<Sighting>.broadcast();
  final _inbound = StreamController<InboundFrame>.broadcast();
  final _status = StreamController<TransportStatus>.broadcast();
  final Map<String, Reassembler> _reassemblers = {};
  final Chunker _chunker = Chunker();
  TransportProviders _providers = TransportProviders(
    presence: () => Uint8List(0),
    profile: () => Uint8List(0),
    board: () => Uint8List(0),
  );
  Uint8List? _eid;
  bool _started = false;

  /// Alle gesendeten Frames (für Tests).
  final List<(PeerId, Uint8List)> sent = [];

  @override
  Stream<Sighting> get sightings => _sightings.stream;
  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Stream<TransportStatus> get statusChanges => _status.stream;
  @override
  TransportStatus get status => TransportStatus.ready;

  Uint8List? get advertisedEid => _eid;

  @override
  void setProviders(TransportProviders providers) => _providers = providers;

  @override
  Future<void> start() async {
    _started = true;
    _status.add(TransportStatus.ready);
  }

  @override
  Future<void> stop() async {
    _started = false;
  }

  @override
  Future<void> setAdvertising(Uint8List? eid) async {
    _eid = eid == null ? null : Uint8List.fromList(eid);
  }

  FakeTransport _peer(PeerId peer) {
    if (!peer.startsWith('f:')) throw TransportException('Unbekannter Peer $peer');
    final node = _world._node(peer.substring(2));
    if (node == null || !node._started) {
      throw TransportException('Peer nicht erreichbar: $peer');
    }
    if (_world._distance(this, node) > _world.maxRangeMeters) {
      throw TransportException('Peer außer Reichweite: $peer');
    }
    return node;
  }

  @override
  Future<Uint8List> read(PeerId peer, ReadTarget target) async {
    final node = _peer(peer);
    await _delay();
    return switch (target) {
      ReadTarget.presence => node._providers.presence(),
      ReadTarget.profile => node._providers.profile(),
      ReadTarget.board => node._providers.board(),
    };
  }

  @override
  Future<void> send(PeerId peer, Uint8List frameBytes) async {
    final node = _peer(peer);
    sent.add((peer, Uint8List.fromList(frameBytes)));
    final chunks = _chunker.split(frameBytes, _world.fakeMtu);
    await _delay();
    for (final chunk in chunks) {
      node._receiveChunk('f:$id', chunk);
    }
  }

  void _receiveChunk(PeerId from, Uint8List chunk) {
    final r = _reassemblers[from] ??= Reassembler();
    final frame = r.accept(chunk);
    if (frame != null) _inbound.add(InboundFrame(from, frame));
  }

  Future<void> _delay() =>
      _world.latency == Duration.zero ? Future.value() : Future.delayed(_world.latency);

  @override
  Future<void> drop(PeerId peer) async {}

  @override
  Future<void> dispose() async {
    _world.remove(id);
    await _sightings.close();
    await _inbound.close();
    await _status.close();
  }
}
