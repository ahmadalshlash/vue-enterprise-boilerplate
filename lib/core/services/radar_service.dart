import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/rssi.dart';
import '../ble/transport.dart';
import '../crypto/eid.dart';
import '../protocol/constants.dart';
import '../protocol/models.dart';

/// Eine Person in Reichweite.
class RadarPeer {
  RadarPeer({required this.peerId, required Uint8List eid, required DateTime firstSeen})
      : _eid = eid,
        lastSeen = firstSeen,
        firstSeen = firstSeen;

  final PeerId peerId;
  Uint8List _eid;
  final DateTime firstSeen;
  DateTime lastSeen;
  final RssiSmoother _rssi = RssiSmoother();
  Presence? presence;
  DateTime? presenceFetchedAt;
  bool fetching = false;
  bool presenceFailed = false;
  bool needsUpdate = false;

  Uint8List get eid => _eid;
  String get eidHex => _eid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  int get rssi => _rssi.value;
  Proximity get proximity => _rssi.proximity;
  String get displayName => presence?.displayName ?? '…';
  String get emoji => presence?.emoji ?? '📡';
  String get status => presence?.status ?? '';
  bool get hasProfile => presence?.hasProfile ?? false;
  VisibilityMode get mode => presence?.mode ?? VisibilityMode.anonymous;
  bool get isResolved => presence != null;
}

/// Radar: wer ist in Reichweite, wie nah, mit welcher Presence.
class RadarService extends ChangeNotifier {
  RadarService(this._transport, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final NearbyTransport _transport;
  final DateTime Function() _clock;
  final Map<PeerId, RadarPeer> _peers = {};
  StreamSubscription? _sub;
  Timer? _timer;

  /// Wird gerufen, wenn ein Peer erstmals aufgelöst wurde (Board-Sync etc.).
  final List<void Function(RadarPeer)> onPeerResolved = [];

  List<RadarPeer> get peers {
    final list = _peers.values.where((p) => p.isResolved || !p.presenceFailed).toList()
      ..sort((a, b) {
        final r = a.proximity.rank.compareTo(b.proximity.rank);
        return r != 0 ? r : b.rssi.compareTo(a.rssi);
      });
    return list;
  }

  List<RadarPeer> get resolvedPeers => peers.where((p) => p.isResolved).toList();
  int get count => resolvedPeers.length;

  void start() {
    _sub ??= _transport.sightings.listen(_onSighting);
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => _sweep());
  }

  Future<void> stop() async {
    // cancel() nicht awaiten: das vorab erzeugte Null-Future hängt in FakeAsync-Zonen.
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _peers.clear();
    notifyListeners();
  }

  void _onSighting(Sighting s) {
    var peer = _peers[s.peerId];
    var changed = false;
    if (peer == null) {
      peer = RadarPeer(peerId: s.peerId, eid: s.eid, firstSeen: s.at);
      _peers[s.peerId] = peer;
      changed = true;
    } else if (s.eid.isNotEmpty && !Eid.equals(s.eid, peer.eid)) {
      // Neue EID (Fenster gewechselt oder Alias neu) → Presence neu laden.
      peer._eid = s.eid;
      peer.presenceFetchedAt = null;
      peer.presenceFailed = false;
      changed = true;
    }
    // Dubletten: gleiche EID unter anderer Transport-ID → alte entfernen.
    if (s.eid.isNotEmpty) {
      _peers.removeWhere((id, p) => id != s.peerId && p.eid.isNotEmpty && Eid.equals(p.eid, s.eid));
    }
    final before = peer.proximity;
    peer.lastSeen = s.at;
    peer._rssi.add(s.rssi);
    if (peer.proximity != before) changed = true;
    if (_needsPresence(peer)) {
      _fetchPresence(peer);
    }
    if (changed) notifyListeners();
  }

  bool _needsPresence(RadarPeer p) {
    if (p.fetching || p.presenceFailed) return false;
    final at = p.presenceFetchedAt;
    if (at == null) return true;
    return _clock().difference(at) > ProtocolConstants.presenceCacheLifetime;
  }

  Future<void> _fetchPresence(RadarPeer peer) async {
    peer.fetching = true;
    try {
      final bytes = await _transport.read(peer.peerId, ReadTarget.presence);
      if (bytes.isEmpty) {
        // Unsichtbar geworden → aus dem Radar nehmen.
        _peers.remove(peer.peerId);
        notifyListeners();
        return;
      }
      final presence = Presence.decode(bytes);
      final wasResolved = peer.isResolved;
      peer.presence = presence;
      peer.needsUpdate = presence.version > ProtocolConstants.version;
      if (peer.eid.isEmpty && presence.eid.isNotEmpty) peer._eid = presence.eid;
      peer.presenceFetchedAt = _clock();
      notifyListeners();
      if (!wasResolved) {
        for (final cb in List.of(onPeerResolved)) {
          cb(peer);
        }
      }
    } catch (e) {
      debugPrint('Radar: Presence von ${peer.peerId} nicht lesbar: $e');
      peer.presenceFailed = true;
      peer.presenceFetchedAt = _clock();
      notifyListeners();
    } finally {
      peer.fetching = false;
    }
  }

  /// Manuelles Neuladen (Pull-to-Refresh).
  Future<void> refresh() async {
    for (final p in _peers.values) {
      p.presenceFetchedAt = null;
      p.presenceFailed = false;
      if (!p.fetching) await _fetchPresence(p);
    }
  }

  void _sweep() {
    final now = _clock();
    final before = _peers.length;
    _peers.removeWhere((_, p) => now.difference(p.lastSeen) > ProtocolConstants.peerTimeout);
    // Fehlgeschlagene Presence-Reads nach einer Minute erneut versuchen.
    for (final p in _peers.values) {
      if (p.presenceFailed &&
          p.presenceFetchedAt != null &&
          now.difference(p.presenceFetchedAt!) > const Duration(minutes: 1)) {
        p.presenceFailed = false;
        p.presenceFetchedAt = null;
      }
    }
    if (_peers.length != before) notifyListeners();
  }

  RadarPeer? byPeerId(PeerId id) => _peers[id];

  /// Findet einen Peer, dessen EID zu einer der [candidates] passt.
  RadarPeer? byEidCandidates(List<Uint8List> candidates) {
    for (final p in _peers.values) {
      if (p.eid.isEmpty) continue;
      for (final c in candidates) {
        if (Eid.equals(c, p.eid)) return p;
      }
    }
    return null;
  }

  /// Merkt sich, dass ein bisher unbekannter Peer (z. B. ein Central,
  /// das uns angeschrieben hat) existiert, ohne ihn im Radar anzuzeigen.
  void forget(PeerId id) {
    if (_peers.remove(id) != null) notifyListeners();
  }
}
