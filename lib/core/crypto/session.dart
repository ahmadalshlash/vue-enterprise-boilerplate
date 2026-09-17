import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protocol/cbor_codec.dart';

/// Ende-zu-Ende-Session mit je einem Richtungsschlüssel.
///
/// Verschlüsselung: XChaCha20-Poly1305, zufällige 24-Byte-Nonce,
/// Drahtformat `nonce || ciphertext || mac`.
class Session {
  Session({
    required this.peerFingerprint,
    required this.peerSigningKey,
    required Uint8List sendKey,
    required Uint8List receiveKey,
  })  : _sendKey = Uint8List.fromList(sendKey),
        _receiveKey = Uint8List.fromList(receiveKey);

  static final _aead = Xchacha20.poly1305Aead();
  static const nonceLength = 24;
  static const macLength = 16;

  final String peerFingerprint;
  final Uint8List peerSigningKey;
  final Uint8List _sendKey;
  final Uint8List _receiveKey;

  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final box = await _aead.encrypt(plaintext, secretKey: SecretKeyData(_sendKey));
    return box.concatenation();
  }

  /// Wirft [SecretBoxAuthenticationError] bei manipulierten Daten.
  Future<Uint8List> decrypt(Uint8List wire) async {
    final box = SecretBox.fromConcatenation(wire, nonceLength: nonceLength, macLength: macLength);
    final clear = await _aead.decrypt(box, secretKey: SecretKeyData(_receiveKey));
    return Uint8List.fromList(clear);
  }

  /// Serialisierung für die lokale, verschlüsselte Datenbank.
  Uint8List serialize() => CborCodec.encode({
        'fp': peerFingerprint,
        'sk': peerSigningKey,
        'send': _sendKey,
        'recv': _receiveKey,
      });

  static Session deserialize(Uint8List bytes) {
    final m = CborCodec.decode(bytes);
    return Session(
      peerFingerprint: m.str('fp'),
      peerSigningKey: m.bytes('sk') ?? Uint8List(0),
      sendKey: m.bytes('send') ?? Uint8List(32),
      receiveKey: m.bytes('recv') ?? Uint8List(32),
    );
  }

  /// Einmalige AEAD-Operation mit einem abgeleiteten Schlüssel (Handshake).
  static Future<Uint8List> seal(Uint8List key, Uint8List plaintext, {List<int> aad = const []}) async {
    final box = await _aead.encrypt(plaintext, secretKey: SecretKeyData(key), aad: aad);
    return box.concatenation();
  }

  static Future<Uint8List> open(Uint8List key, Uint8List wire, {List<int> aad = const []}) async {
    final box = SecretBox.fromConcatenation(wire, nonceLength: nonceLength, macLength: macLength);
    final clear = await _aead.decrypt(box, secretKey: SecretKeyData(key), aad: aad);
    return Uint8List.fromList(clear);
  }
}
