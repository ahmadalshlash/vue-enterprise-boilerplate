import 'package:flutter/foundation.dart';

/// Transport-Kennung eines Gegenübers. Sie ist nur für die Dauer einer
/// Verbindung gültig und sagt nichts über die Person aus; Personen werden
/// über EID (Radar) bzw. Fingerabdruck (Chat) identifiziert.
///
/// Konvention: `p:<id>` = Peripheral, zu dem wir verbunden sind,
/// `c:<id>` = Central, das mit uns verbunden ist, `f:<id>` = Fake.
typedef PeerId = String;

/// Ein Advertising-Paket wurde gesehen.
@immutable
class Sighting {
  const Sighting({
    required this.peerId,
    required this.eid,
    required this.rssi,
    required this.at,
  });

  final PeerId peerId;

  /// EID aus dem Advertising-Namen. Leer, wenn der Name fehlte
  /// (iOS im Hintergrund); dann liefert erst Presence die EID.
  final Uint8List eid;
  final int rssi;
  final DateTime at;
}

/// Ein vollständig zusammengesetztes Frame von einem Peer.
@immutable
class InboundFrame {
  const InboundFrame(this.peerId, this.bytes);
  final PeerId peerId;
  final Uint8List bytes;
}

/// Lesbare Characteristics des Gegenübers.
enum ReadTarget { presence, profile, board }

/// Zustand des Funk-Stacks.
enum TransportStatus { unknown, unsupported, unauthorized, poweredOff, ready }

/// Lieferanten für die eigenen lesbaren Characteristics (GATT-Server).
class TransportProviders {
  const TransportProviders({
    required this.presence,
    required this.profile,
    required this.board,
  });

  final Uint8List Function() presence;
  final Uint8List Function() profile;
  final Uint8List Function() board;
}

/// Abstraktion über den Nahbereichs-Transport. Die produktive
/// Implementierung ist [BleTransport]; Tests und Demo nutzen [FakeTransport].
abstract class NearbyTransport {
  Stream<Sighting> get sightings;
  Stream<InboundFrame> get inbound;
  Stream<TransportStatus> get statusChanges;
  TransportStatus get status;

  /// Setzt die Datenquellen für die eigenen Characteristics.
  void setProviders(TransportProviders providers);

  /// Startet Scannen und GATT-Server. Advertising separat über [setAdvertising].
  Future<void> start();
  Future<void> stop();

  /// Startet/aktualisiert Advertising mit [eid]; `null` = unsichtbar.
  Future<void> setAdvertising(Uint8List? eid);

  Future<Uint8List> read(PeerId peer, ReadTarget target);

  /// Sendet ein kodiertes Frame; Chunking übernimmt der Transport.
  Future<void> send(PeerId peer, Uint8List frameBytes);

  /// Trennt eine Verbindung aktiv (z. B. nach Blockieren).
  Future<void> drop(PeerId peer);

  Future<void> dispose();
}

class TransportException implements Exception {
  const TransportException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'TransportException: $message${cause == null ? '' : ' ($cause)'}';
}
