import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import 'key_store.dart';
import 'random.dart';

/// Geräte-Identität: Ed25519 zum Signieren, X25519 als statischer
/// Schlüssel für den Handshake. Beide werden aus je einem 32-Byte-Seed
/// im [KeyStore] abgeleitet.
class DeviceIdentity {
  DeviceIdentity._(this._signingPair, this._staticPair, this.signingPublicKey, this.staticPublicKey);

  static const _signingSeedKey = 'identity.ed25519.seed';
  static const _staticSeedKey = 'identity.x25519.seed';

  final SimpleKeyPair _signingPair;
  final SimpleKeyPair _staticPair;

  /// Ed25519-Public-Key (32 Byte).
  final Uint8List signingPublicKey;

  /// X25519-Public-Key (32 Byte).
  final Uint8List staticPublicKey;

  SimpleKeyPair get signingKeyPair => _signingPair;
  SimpleKeyPair get staticKeyPair => _staticPair;

  /// Fingerabdruck = erste 16 Byte von SHA-256 über den Ed25519-Public-Key.
  late final String fingerprint = fingerprintOf(signingPublicKey);

  static String fingerprintOf(Uint8List signingPublicKey) {
    final digest = sha256.convert(signingPublicKey).bytes;
    return _hex(digest.sublist(0, 16));
  }

  /// Lädt die Identität oder erzeugt sie beim ersten Start.
  static Future<DeviceIdentity> loadOrCreate(KeyStore store) async {
    var signingSeed = await store.read(_signingSeedKey);
    var staticSeed = await store.read(_staticSeedKey);
    if (signingSeed == null || staticSeed == null) {
      signingSeed = randomBytes(32);
      staticSeed = randomBytes(32);
      await store.write(_signingSeedKey, signingSeed);
      await store.write(_staticSeedKey, staticSeed);
    }
    return fromSeeds(signingSeed: signingSeed, staticSeed: staticSeed);
  }

  static Future<DeviceIdentity> fromSeeds({
    required Uint8List signingSeed,
    required Uint8List staticSeed,
  }) async {
    final signing = await Ed25519().newKeyPairFromSeed(signingSeed);
    final static_ = await X25519().newKeyPairFromSeed(staticSeed);
    final signingPub = await signing.extractPublicKey();
    final staticPub = await static_.extractPublicKey();
    return DeviceIdentity._(
      signing,
      static_,
      Uint8List.fromList(signingPub.bytes),
      Uint8List.fromList(staticPub.bytes),
    );
  }

  /// Erzeugt eine frische, zufällige Identität (Tests, Demo-Peers).
  static Future<DeviceIdentity> random() =>
      fromSeeds(signingSeed: randomBytes(32), staticSeed: randomBytes(32));

  Future<Uint8List> sign(List<int> message) async {
    final sig = await Ed25519().sign(message, keyPair: _signingPair);
    return Uint8List.fromList(sig.bytes);
  }

  static Future<bool> verify(List<int> message, Uint8List signature, Uint8List publicKey) {
    if (signature.length != 64 || publicKey.length != 32) return Future.value(false);
    return Ed25519().verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  }

  static Future<void> reset(KeyStore store) async {
    await store.delete(_signingSeedKey);
    await store.delete(_staticSeedKey);
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Öffentliche Hilfsfunktion für Hex-Darstellung.
String bytesToHex(List<int> bytes) => _hex(bytes);

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
