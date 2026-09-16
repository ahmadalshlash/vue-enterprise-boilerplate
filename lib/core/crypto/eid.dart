import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/constants.dart';

/// Ephemeral-ID (EID): 8 Byte, alle 15 Minuten neu, aus einem geheimen
/// Alias-Secret abgeleitet. Siehe konzept/protokoll.md Abschnitt 2.2.
class Eid {
  Eid._();

  static int epochFor(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ ProtocolConstants.eidEpochSeconds;

  /// `eid = HMAC-SHA256(alias_secret, "eid" || epoch)[0..8]`
  static Uint8List derive(Uint8List aliasSecret, int epoch) {
    final msg = BytesBuilder(copy: false)
      ..add(utf8.encode('eid'))
      ..add(_epochBytes(epoch));
    final mac = Hmac(sha256, aliasSecret).convert(msg.takeBytes());
    return Uint8List.fromList(mac.bytes.sublist(0, ProtocolConstants.eidLength));
  }

  static Uint8List current(Uint8List aliasSecret, DateTime now) =>
      derive(aliasSecret, epochFor(now));

  /// EIDs für vorheriges, aktuelles und nächstes Fenster – damit ein Peer
  /// über die Fenstergrenze hinweg wiedererkannt wird.
  static List<Uint8List> candidates(Uint8List aliasSecret, DateTime now) {
    final e = epochFor(now);
    return [derive(aliasSecret, e - 1), derive(aliasSecret, e), derive(aliasSecret, e + 1)];
  }

  /// Zeitpunkt, an dem das aktuelle Fenster endet.
  static DateTime nextRotation(DateTime now) {
    final nextEpoch = epochFor(now) + 1;
    return DateTime.fromMillisecondsSinceEpoch(
      nextEpoch * ProtocolConstants.eidEpochSeconds * 1000,
      isUtc: true,
    );
  }

  /// Kodierung für den Advertising-Namen: 'N' + Base64url ohne Padding.
  static String toAdvertisingName(Uint8List eid) =>
      ProtocolConstants.advertisingNamePrefix + base64Url.encode(eid).replaceAll('=', '');

  /// Dekodiert einen Advertising-Namen; `null`, wenn er nicht zur App gehört.
  static Uint8List? fromAdvertisingName(String? name) {
    if (name == null || !name.startsWith(ProtocolConstants.advertisingNamePrefix)) {
      return null;
    }
    var b64 = name.substring(ProtocolConstants.advertisingNamePrefix.length);
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    try {
      final bytes = base64Url.decode(b64);
      if (bytes.length != ProtocolConstants.eidLength) return null;
      return Uint8List.fromList(bytes);
    } on FormatException {
      return null;
    }
  }

  /// 8 Byte Big-Endian. Bewusst ohne `setInt64`, das im Web (dart2js)
  /// nicht unterstützt wird; Epochen passen problemlos in 53 Bit.
  static Uint8List _epochBytes(int epoch) {
    final out = Uint8List(8);
    var v = epoch;
    for (var i = 7; i >= 0; i--) {
      out[i] = v & 0xff;
      v = v ~/ 256;
    }
    return out;
  }

  static bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
