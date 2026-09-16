/// Protokoll-Konstanten. Siehe konzept/protokoll.md.
///
/// Die Service-UUID ändert sich NIE, sonst finden sich alte und neue
/// App-Versionen nicht mehr.
library;

class ProtocolConstants {
  ProtocolConstants._();

  /// Aktuelle Protokollversion (Frame-Header und Presence).
  static const int version = 1;

  /// Feste Service-UUID der App im Advertising und als GATT-Dienst.
  static const String serviceUuid = '7e1a3f00-9c4b-4d2e-8f5a-2b6c1d0e9a11';

  /// GATT-Characteristics (Suffix …0001 bis …0005).
  static const String presenceUuid = '7e1a3f00-9c4b-4d2e-8f5a-2b6c1d0e0001';
  static const String inboxUuid = '7e1a3f00-9c4b-4d2e-8f5a-2b6c1d0e0002';
  static const String outboxUuid = '7e1a3f00-9c4b-4d2e-8f5a-2b6c1d0e0003';
  static const String profileUuid = '7e1a3f00-9c4b-4d2e-8f5a-2b6c1d0e0004';
  static const String boardUuid = '7e1a3f00-9c4b-4d2e-8f5a-2b6c1d0e0005';

  /// Präfix des lokalen Namens im Advertising: 'N' + Base64url(EID).
  static const String advertisingNamePrefix = 'N';

  /// Länge der Ephemeral-ID in Byte.
  static const int eidLength = 8;

  /// Lebensdauer eines EID-Fensters in Sekunden (15 Minuten).
  static const int eidEpochSeconds = 900;

  /// Lebensdauer eines Alias (24 h).
  static const Duration aliasLifetime = Duration(hours: 24);

  /// Peer gilt als „nicht mehr in Reichweite“ ohne Paket seit …
  static const Duration peerTimeout = Duration(seconds: 20);

  /// Presence-Cache je Peer, danach wird neu gelesen.
  static const Duration presenceCacheLifetime = Duration(seconds: 60);

  /// Unvollständige Chunk-Puffer werden nach dieser Zeit verworfen.
  static const Duration chunkTimeout = Duration(seconds: 5);

  /// Maximale Frame-Größe im MVP (Text).
  static const int maxFrameBytes = 4096;

  /// Konservativer MTU-Fallback (BLE 4.2 Standard-MTU 23 → 20 Byte Nutzlast).
  static const int minimumMtu = 23;

  /// Ziel-MTU nach Aushandlung.
  static const int preferredMtu = 512;

  /// Maximale Länge eines Board-Posts in Zeichen.
  static const int maxPostChars = 500;

  /// Maximale Länge einer Chat-Nachricht in Zeichen.
  static const int maxMessageChars = 2000;

  /// Outbox-Einträge verfallen nach 7 Tagen.
  static const Duration outboxLifetime = Duration(days: 7);

  /// Rate-Limit: Posts pro Absender-Schlüssel je Fenster.
  static const int postsPerWindow = 5;
  static const Duration postWindow = Duration(minutes: 10);

  /// Rate-Limit: Verbindungsversuche pro Peer je Minute.
  static const int connectsPerMinute = 3;

  /// Standard-Ablaufzeit eines Posts.
  static const Duration defaultPostTtl = Duration(hours: 6);

  /// Domain-Separator für Handshake und Signaturen.
  static const String handshakeLabel = 'umkreis/hs/1';
  static const String postSignLabel = 'umkreis/post/1';
  static const String profileSignLabel = 'umkreis/profile/1';
}
