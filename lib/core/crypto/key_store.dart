import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Abstraktion über den sicheren Schlüsselspeicher (Keychain / Keystore).
abstract class KeyStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List value);
  Future<void> delete(String key);
}

/// Speicher im Arbeitsspeicher – für Tests und den Demo-Modus.
class InMemoryKeyStore implements KeyStore {
  final Map<String, Uint8List> _data = {};

  @override
  Future<Uint8List?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, Uint8List value) async {
    _data[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

/// Produktiver Speicher über `flutter_secure_storage`.
class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read(String key) async {
    final v = await _storage.read(key: key);
    return v == null ? null : base64Decode(v);
  }

  @override
  Future<void> write(String key, Uint8List value) =>
      _storage.write(key: key, value: base64Encode(value));

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
