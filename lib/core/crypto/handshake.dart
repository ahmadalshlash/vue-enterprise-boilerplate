import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protocol/cbor_codec.dart';
import '../protocol/constants.dart';
import 'identity.dart';
import 'session.dart';

/// Authentifizierter Drei-Nachrichten-Handshake nach dem Muster von
/// Noise XX (ephemer-ephemer, dann beidseitig statische Schlüssel,
/// die verschlüsselt übertragen werden). Die Authentifizierung erfolgt
/// über Ed25519-Signaturen über das Transkript, sodass die Geräte-
/// Identität nie im Klartext über die Luft geht.
///
/// ```text
/// A → B  msg1 = eA
/// B → A  msg2 = eB || AEAD(kResp, {sB, idB, sigB})
/// A → B  msg3 = AEAD(kInit, {sA, idA, sigA}) || AEAD(sendKeyA, payload)
/// ```
///
/// mit
/// ```text
/// transcript = label || eA || eB
/// ee = DH(eA, eB), es = DH(eA, sB), se = DH(sA, eB)
/// kResp  = HKDF(ee,               salt=transcript, info="resp-static")
/// kInit  = HKDF(ee || es,         salt=transcript, info="init-static")
/// master = HKDF(ee || es || se,   salt=transcript, info="session")
/// keyA→B = HKDF(master, info="a2b"), keyB→A = HKDF(master, info="b2a")
/// ```
class Handshake {
  Handshake._();

  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<HandshakeInitiator> initiate(DeviceIdentity identity) async {
    final eph = await _x25519.newKeyPair();
    final pub = await eph.extractPublicKey();
    return HandshakeInitiator._(identity, eph, Uint8List.fromList(pub.bytes));
  }

  /// B verarbeitet msg1 und erzeugt msg2.
  static Future<HandshakeResponder> respond(DeviceIdentity identity, Uint8List msg1) async {
    if (msg1.length != 32) throw const HandshakeException('msg1 hat falsche Länge');
    final eph = await _x25519.newKeyPair();
    final ePub = Uint8List.fromList((await eph.extractPublicKey()).bytes);
    final transcript = _transcript(msg1, ePub);

    final ee = await _dh(eph, msg1);
    final kResp = await _kdf(ee, transcript, 'resp-static');
    final bundle = await _staticBundle(identity, transcript, 'resp');
    final sealed = await Session.seal(kResp, bundle, aad: transcript);

    final msg2 = Uint8List.fromList([...ePub, ...sealed]);
    return HandshakeResponder._(identity, eph, ePub, msg1, transcript, ee, msg2);
  }

  static Uint8List _transcript(Uint8List eA, Uint8List eB) =>
      Uint8List.fromList([...utf8.encode(ProtocolConstants.handshakeLabel), ...eA, ...eB]);

  static Future<Uint8List> _dh(SimpleKeyPair mine, Uint8List theirPublic) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirPublic, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  static Future<Uint8List> _kdf(List<int> ikm, List<int> salt, String info) async {
    final key = await _hkdf.deriveKey(
      secretKey: SecretKeyData(ikm),
      nonce: salt,
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<Uint8List> _staticBundle(DeviceIdentity id, Uint8List transcript, String role) async {
    final toSign = Uint8List.fromList([...transcript, ...utf8.encode(role), ...id.staticPublicKey]);
    final sig = await id.sign(toSign);
    return CborCodec.encode({
      'sx': id.staticPublicKey,
      'id': id.signingPublicKey,
      'sig': sig,
    });
  }

  static Future<_PeerStatic> _openBundle(Uint8List clear, Uint8List transcript, String role) async {
    final m = CborCodec.decode(clear);
    final sx = m.bytes('sx');
    final id = m.bytes('id');
    final sig = m.bytes('sig');
    if (sx == null || id == null || sig == null || sx.length != 32 || id.length != 32) {
      throw const HandshakeException('Statisches Bündel unvollständig');
    }
    final toVerify = Uint8List.fromList([...transcript, ...utf8.encode(role), ...sx]);
    if (!await DeviceIdentity.verify(toVerify, sig, id)) {
      throw const HandshakeException('Signatur des Peers ungültig');
    }
    return _PeerStatic(sx, id);
  }

  static Future<(Uint8List, Uint8List)> _sessionKeys(
    Uint8List ee,
    Uint8List es,
    Uint8List se,
    Uint8List transcript,
  ) async {
    final master = await _kdf([...ee, ...es, ...se], transcript, 'session');
    final a2b = await _kdf(master, transcript, 'a2b');
    final b2a = await _kdf(master, transcript, 'b2a');
    return (a2b, b2a);
  }
}

class _PeerStatic {
  _PeerStatic(this.staticKey, this.signingKey);
  final Uint8List staticKey;
  final Uint8List signingKey;
}

/// Zustand von A (Initiator) zwischen msg1 und msg3.
class HandshakeInitiator {
  HandshakeInitiator._(this._identity, this._eph, this.msg1);

  final DeviceIdentity _identity;
  final SimpleKeyPair _eph;

  /// An B zu sendendes msg1 (32 Byte ephemerer Public Key).
  final Uint8List msg1;

  /// Verarbeitet msg2, erzeugt msg3 (mit [payload] als erste verschlüsselte
  /// Nachricht) und liefert die fertige Session.
  Future<(Uint8List msg3, Session session)> finish(Uint8List msg2, Uint8List payload) async {
    if (msg2.length < 32 + Session.nonceLength + Session.macLength) {
      throw const HandshakeException('msg2 zu kurz');
    }
    final eB = Uint8List.sublistView(msg2, 0, 32);
    final sealed = Uint8List.sublistView(msg2, 32);
    final transcript = Handshake._transcript(msg1, eB);

    final ee = await Handshake._dh(_eph, eB);
    final kResp = await Handshake._kdf(ee, transcript, 'resp-static');
    final Uint8List clear;
    try {
      clear = await Session.open(kResp, sealed, aad: transcript);
    } on SecretBoxAuthenticationError {
      throw const HandshakeException('msg2 nicht entschlüsselbar');
    }
    final peer = await Handshake._openBundle(clear, transcript, 'resp');

    final es = await Handshake._dh(_eph, peer.staticKey);
    final se = await Handshake._dh(_identity.staticKeyPair, eB);

    final kInit = await Handshake._kdf([...ee, ...es], transcript, 'init-static');
    final bundle = await Handshake._staticBundle(_identity, transcript, 'init');
    final sealedBundle = await Session.seal(kInit, bundle, aad: transcript);

    final (a2b, b2a) = await Handshake._sessionKeys(ee, es, se, transcript);
    final session = Session(
      peerFingerprint: DeviceIdentity.fingerprintOf(peer.signingKey),
      peerSigningKey: peer.signingKey,
      sendKey: a2b,
      receiveKey: b2a,
    );
    final sealedPayload = await session.encrypt(payload);

    final msg3 = CborCodec.encode({'b': sealedBundle, 'p': sealedPayload});
    return (msg3, session);
  }
}

/// Zustand von B (Responder) zwischen msg2 und msg3.
class HandshakeResponder {
  HandshakeResponder._(
    this._identity,
    this._eph,
    this._ePub,
    this._eA,
    this._transcript,
    this._ee,
    this.msg2,
  );

  final DeviceIdentity _identity;
  final SimpleKeyPair _eph;
  // ignore: unused_field
  final Uint8List _ePub;
  final Uint8List _eA;
  final Uint8List _transcript;
  final Uint8List _ee;

  /// An A zu sendendes msg2.
  final Uint8List msg2;

  /// Verarbeitet msg3 und liefert Session sowie die erste Klartext-Nachricht.
  Future<(Session session, Uint8List payload)> finish(Uint8List msg3) async {
    final m = CborCodec.decode(msg3);
    final sealedBundle = m.bytes('b');
    final sealedPayload = m.bytes('p');
    if (sealedBundle == null || sealedPayload == null) {
      throw const HandshakeException('msg3 unvollständig');
    }

    final es = await Handshake._dh(_identity.staticKeyPair, _eA);
    final kInit = await Handshake._kdf([..._ee, ...es], _transcript, 'init-static');
    final Uint8List clear;
    try {
      clear = await Session.open(kInit, sealedBundle, aad: _transcript);
    } on SecretBoxAuthenticationError {
      throw const HandshakeException('msg3 nicht entschlüsselbar');
    }
    final peer = await Handshake._openBundle(clear, _transcript, 'init');
    final se = await Handshake._dh(_eph, peer.staticKey);

    final (a2b, b2a) = await Handshake._sessionKeys(_ee, es, se, _transcript);
    final session = Session(
      peerFingerprint: DeviceIdentity.fingerprintOf(peer.signingKey),
      peerSigningKey: peer.signingKey,
      sendKey: b2a,
      receiveKey: a2b,
    );
    final Uint8List payload;
    try {
      payload = await session.decrypt(sealedPayload);
    } on SecretBoxAuthenticationError {
      throw const HandshakeException('Erste Nachricht nicht entschlüsselbar');
    }
    return (session, payload);
  }
}

class HandshakeException implements Exception {
  const HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'HandshakeException: $message';
}
