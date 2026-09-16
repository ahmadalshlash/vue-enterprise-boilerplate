import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../crypto/alias.dart';
import '../crypto/eid.dart';
import '../crypto/identity.dart';
import '../crypto/random.dart';
import '../protocol/cbor_codec.dart';
import '../protocol/constants.dart';
import '../protocol/models.dart';
import '../storage/app_database.dart';

/// Wer bin ich gerade: Modus, Alias (mit Secret und Rotation), Profil,
/// Status-Zeile, Sprache. Liefert Presence und signiertes Profil für
/// den GATT-Server.
class IdentityService extends ChangeNotifier {
  IdentityService(this._settings, this.identity, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final SettingsRepository _settings;
  final DeviceIdentity identity;
  final DateTime Function() _clock;

  VisibilityMode _mode = VisibilityMode.anonymous;
  Uint8List _aliasSecret = Uint8List(0);
  DateTime _aliasCreatedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _alias = '';
  String _emoji = '';
  String _status = '';
  Profile? _profile;
  String _language = 'de';
  bool _onboardingDone = false;
  SimpleKeyPair? _postKeyPair;
  Uint8List? _postPublicKey;

  VisibilityMode get mode => _mode;
  Uint8List get aliasSecret => _aliasSecret;
  String get alias => _alias;
  String get emoji => _emoji;
  String get status => _status;
  Profile? get profile => _profile;
  String get language => _language;
  bool get onboardingDone => _onboardingDone;
  bool get hasProfile => _profile != null && _profile!.name.trim().isNotEmpty;
  DateTime get aliasCreatedAt => _aliasCreatedAt;
  DateTime get aliasExpiresAt => _aliasCreatedAt.add(ProtocolConstants.aliasLifetime);

  /// Anzeigename je nach Modus.
  String get displayName => _mode == VisibilityMode.profile && hasProfile ? _profile!.name : _alias;
  String get displayEmoji => _mode == VisibilityMode.profile && hasProfile ? _profile!.emoji : _emoji;

  Future<void> load() async {
    final modeIdx = await _settings.get<int>('mode');
    _mode = modeIdx == null ? VisibilityMode.anonymous : VisibilityMode.fromWire(modeIdx);
    _language = await _settings.get<String>('language') ?? 'de';
    _status = await _settings.get<String>('status') ?? '';
    _onboardingDone = await _settings.get<bool>('onboardingDone') ?? false;
    final profileMap = await _settings.get<Map<String, Object?>>('profile');
    if (profileMap != null) _profile = Profile.fromMap(profileMap);

    final secret = await _settings.getBytes('aliasSecret');
    final createdMs = await _settings.get<int>('aliasCreatedAt');
    if (secret == null || createdMs == null) {
      await rerollAlias(notify: false);
    } else {
      _aliasSecret = secret;
      _aliasCreatedAt = DateTime.fromMillisecondsSinceEpoch(createdMs);
      await _deriveAlias();
      await rotateAliasIfExpired(notify: false);
    }
    notifyListeners();
  }

  Future<void> _deriveAlias() async {
    final (a, e) = AliasGenerator.generate(_aliasSecret, language: _language);
    _alias = a;
    _emoji = e;
    final seed = Uint8List.fromList(
      (await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
              .deriveKey(secretKey: SecretKeyData(_aliasSecret), nonce: const [], info: 'postkey'.codeUnits))
          .bytes,
    );
    _postKeyPair = await Ed25519().newKeyPairFromSeed(seed);
    _postPublicKey = Uint8List.fromList((await _postKeyPair!.extractPublicKey()).bytes);
  }

  /// Neuer Alias (neues Secret → neue EIDs, neuer Post-Schlüssel).
  Future<void> rerollAlias({bool notify = true}) async {
    _aliasSecret = randomBytes(32);
    _aliasCreatedAt = _clock();
    await _settings.setBytes('aliasSecret', _aliasSecret);
    await _settings.set('aliasCreatedAt', _aliasCreatedAt.millisecondsSinceEpoch);
    await _deriveAlias();
    if (notify) notifyListeners();
  }

  /// Rotiert den Alias, wenn er älter als 24 h ist. Gibt `true` bei Rotation zurück.
  Future<bool> rotateAliasIfExpired({bool notify = true}) async {
    if (_clock().isBefore(aliasExpiresAt)) return false;
    await rerollAlias(notify: notify);
    return true;
  }

  Uint8List currentEid() => Eid.current(_aliasSecret, _clock());
  DateTime nextEidRotation() => Eid.nextRotation(_clock());

  bool get isVisible => _mode != VisibilityMode.invisible;

  Future<void> setMode(VisibilityMode m) async {
    if (m == VisibilityMode.profile && !hasProfile) {
      throw StateError('Profil-Modus ohne Profil');
    }
    _mode = m;
    await _settings.set('mode', m.wire);
    notifyListeners();
  }

  Future<void> setStatus(String s) async {
    _status = s.trim().length > 80 ? s.trim().substring(0, 80) : s.trim();
    await _settings.set('status', _status);
    notifyListeners();
  }

  Future<void> setProfile(Profile? p) async {
    _profile = p;
    if (p == null) {
      await _settings.remove('profile');
      if (_mode == VisibilityMode.profile) _mode = VisibilityMode.anonymous;
    } else {
      await _settings.set('profile', p.toMap());
    }
    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    _language = lang;
    await _settings.set('language', lang);
    await _deriveAlias();
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    _onboardingDone = true;
    await _settings.set('onboardingDone', true);
    notifyListeners();
  }

  /// Presence für die GATT-Characteristic. Im Modus „Unsichtbar“ leer.
  Presence presence() => Presence(
        mode: _mode,
        alias: displayName,
        emoji: displayEmoji,
        status: _status,
        hasProfile: _mode == VisibilityMode.profile && hasProfile,
        eid: currentEid(),
      );

  Uint8List presenceBytes() => isVisible ? presence().encode() : Uint8List(0);

  /// Signiertes Profil: `{profile, pubkey, sig}`, sig über label||CBOR(profile).
  Future<Uint8List> signedProfileBytes() async {
    final p = _profile;
    if (p == null || _mode != VisibilityMode.profile) return Uint8List(0);
    return signProfile(p);
  }

  Future<Uint8List> signProfile(Profile p) async {
    final body = CborCodec.encode(p.toMap());
    final sig = await identity.sign([...ProtocolConstants.profileSignLabel.codeUnits, ...body]);
    return CborCodec.encode({'profile': body, 'pubkey': identity.signingPublicKey, 'sig': sig});
  }

  /// Prüft ein signiertes Profil; liefert (Profil, Fingerabdruck) oder null.
  static Future<(Profile, String)?> verifySignedProfile(Uint8List bytes) async {
    try {
      final m = CborCodec.decode(bytes);
      final body = m.bytes('profile');
      final pub = m.bytes('pubkey');
      final sig = m.bytes('sig');
      if (body == null || pub == null || sig == null) return null;
      final ok = await DeviceIdentity.verify([...ProtocolConstants.profileSignLabel.codeUnits, ...body], sig, pub);
      if (!ok) return null;
      return (Profile.fromMap(CborCodec.decode(body)), DeviceIdentity.fingerprintOf(pub));
    } catch (_) {
      return null;
    }
  }

  /// Schlüssel zum Signieren anonymer Posts (rotiert mit dem Alias).
  Future<Uint8List> signAsPoster(List<int> message, {required bool asProfile}) async {
    if (asProfile) return identity.sign(message);
    final sig = await Ed25519().sign(message, keyPair: _postKeyPair!);
    return Uint8List.fromList(sig.bytes);
  }

  Uint8List posterPublicKey({required bool asProfile}) =>
      asProfile ? identity.signingPublicKey : _postPublicKey!;

  /// Signierte Presence-Bytes sind nicht nötig; Presence ist unverbindlich.
  /// Dieses Bündel geht verschlüsselt an Kontakte, damit sie meine EIDs
  /// wiedererkennen (Store-and-Forward).
  Uint8List contactKeyBytes() => CborCodec.encode({
        'aliasSecret': _aliasSecret,
        'createdAt': _aliasCreatedAt.millisecondsSinceEpoch,
      });
}
