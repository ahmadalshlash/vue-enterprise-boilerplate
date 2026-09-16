import 'dart:typed_data';

import 'constants.dart';

/// Frame-Typen laut konzept/protokoll.md Abschnitt 5.
enum FrameType {
  hello(0x01),
  handshake(0x02),
  msg(0x10),
  ack(0x11),
  post(0x20),
  postReact(0x21),
  postSyncReq(0x22),
  reveal(0x30),
  error(0x7f);

  const FrameType(this.code);
  final int code;

  static FrameType? fromCode(int code) {
    for (final t in FrameType.values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// Ein logisches Frame: `ver(1) | type(1) | len(2) | payload`.
class Frame {
  Frame(this.type, this.payload, {this.version = ProtocolConstants.version});

  final int version;
  final FrameType type;
  final Uint8List payload;

  static const int headerLength = 4;

  Uint8List encode() {
    if (payload.length > 0xffff) {
      throw ArgumentError('Payload zu groß: ${payload.length}');
    }
    final out = Uint8List(headerLength + payload.length);
    out[0] = version;
    out[1] = type.code;
    out[2] = (payload.length >> 8) & 0xff;
    out[3] = payload.length & 0xff;
    out.setRange(headerLength, out.length, payload);
    return out;
  }

  /// Dekodiert ein Frame. Wirft [FrameFormatException] bei ungültigen Daten
  /// und [UnsupportedFrameVersion] bei einer höheren Protokollversion.
  static Frame decode(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const FrameFormatException('Frame zu kurz');
    }
    final version = bytes[0];
    if (version > ProtocolConstants.version) {
      throw UnsupportedFrameVersion(version);
    }
    final type = FrameType.fromCode(bytes[1]);
    if (type == null) {
      throw FrameFormatException('Unbekannter Frame-Typ 0x${bytes[1].toRadixString(16)}');
    }
    final len = (bytes[2] << 8) | bytes[3];
    if (bytes.length != headerLength + len) {
      throw FrameFormatException(
        'Längenfeld $len passt nicht zu ${bytes.length - headerLength} Byte Payload',
      );
    }
    return Frame(
      type,
      Uint8List.sublistView(bytes, headerLength),
      version: version,
    );
  }
}

class FrameFormatException implements Exception {
  const FrameFormatException(this.message);
  final String message;
  @override
  String toString() => 'FrameFormatException: $message';
}

class UnsupportedFrameVersion implements Exception {
  const UnsupportedFrameVersion(this.version);
  final int version;
  @override
  String toString() => 'UnsupportedFrameVersion: $version';
}
