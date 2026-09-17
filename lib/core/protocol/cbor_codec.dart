import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// Kompakte Kodierung strukturierter Nutzdaten als CBOR.
///
/// Unterstützte Werte: `null`, `bool`, `int`, `double`, `String`,
/// `Uint8List`/`List<int>` (als Bytes), `List`, `Map<String, dynamic>`.
class CborCodec {
  CborCodec._();

  static Uint8List encode(Map<String, Object?> map) {
    return Uint8List.fromList(cbor.encode(_toCbor(map)));
  }

  static Map<String, Object?> decode(Uint8List bytes) {
    final value = cbor.decode(bytes);
    final obj = _fromCbor(value);
    if (obj is! Map) {
      throw const FormatException('CBOR-Wurzel ist keine Map');
    }
    return obj.map((k, v) => MapEntry(k.toString(), v));
  }

  static CborValue _toCbor(Object? v) {
    if (v == null) return const CborNull();
    if (v is bool) return CborBool(v);
    if (v is int) return CborSmallInt(v);
    if (v is double) return CborFloat(v);
    if (v is String) return CborString(v);
    if (v is Uint8List) return CborBytes(v);
    if (v is Map) {
      return CborMap({
        for (final e in v.entries) CborString(e.key.toString()): _toCbor(e.value),
      });
    }
    if (v is List<int>) return CborBytes(v);
    if (v is Iterable) return CborList([for (final e in v) _toCbor(e)]);
    throw ArgumentError('Nicht kodierbar: ${v.runtimeType}');
  }

  static Object? _fromCbor(CborValue v) {
    if (v is CborNull) return null;
    if (v is CborBool) return v.value;
    if (v is CborInt) return v.toInt();
    if (v is CborFloat) return v.value;
    if (v is CborString) return v.toString();
    if (v is CborBytes) return Uint8List.fromList(v.bytes);
    if (v is CborMap) {
      return {
        for (final e in v.entries) _fromCbor(e.key).toString(): _fromCbor(e.value),
      };
    }
    if (v is CborList) return [for (final e in v) _fromCbor(e)];
    throw FormatException('Nicht dekodierbar: ${v.runtimeType}');
  }
}

/// Hilfsfunktionen für dekodierte CBOR-Maps.
extension CborMapReader on Map<String, Object?> {
  String str(String key, {String fallback = ''}) {
    final v = this[key];
    return v is String ? v : fallback;
  }

  int integer(String key, {int fallback = 0}) {
    final v = this[key];
    return v is int ? v : fallback;
  }

  bool boolean(String key, {bool fallback = false}) {
    final v = this[key];
    return v is bool ? v : fallback;
  }

  Uint8List? bytes(String key) {
    final v = this[key];
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    return null;
  }

  List<Object?> list(String key) {
    final v = this[key];
    return v is List ? v : const [];
  }

  Map<String, Object?>? submap(String key) {
    final v = this[key];
    if (v is Map<String, Object?>) return v;
    if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
    return null;
  }
}
