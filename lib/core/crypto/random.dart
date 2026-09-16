import 'dart:math';
import 'dart:typed_data';

final Random _secure = Random.secure();

/// Kryptografisch sichere Zufallsbytes.
Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}

/// Zufällige, hex-kodierte ID (Standard: 16 Byte → 32 Zeichen).
String randomId([int bytes = 16]) =>
    randomBytes(bytes).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
