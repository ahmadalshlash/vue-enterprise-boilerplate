import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umkreis/core/crypto/alias.dart';
import 'package:umkreis/core/crypto/eid.dart';
import 'package:umkreis/core/crypto/handshake.dart';
import 'package:umkreis/core/crypto/identity.dart';
import 'package:umkreis/core/crypto/key_store.dart';
import 'package:umkreis/core/crypto/random.dart';
import 'package:umkreis/core/crypto/session.dart';

void main() {
  group('DeviceIdentity', () {
    test('is persisted and reloaded from the key store', () async {
      final store = InMemoryKeyStore();
      final a = await DeviceIdentity.loadOrCreate(store);
      final b = await DeviceIdentity.loadOrCreate(store);
      expect(a.fingerprint, b.fingerprint);
      expect(a.fingerprint.length, 32);
      expect(a.signingPublicKey, b.signingPublicKey);
    });

    test('sign/verify', () async {
      final id = await DeviceIdentity.random();
      final msg = utf8.encode('hallo');
      final sig = await id.sign(msg);
      expect(await DeviceIdentity.verify(msg, sig, id.signingPublicKey), true);
      expect(await DeviceIdentity.verify(utf8.encode('hallo!'), sig, id.signingPublicKey), false);
      final other = await DeviceIdentity.random();
      expect(await DeviceIdentity.verify(msg, sig, other.signingPublicKey), false);
    });
  });

  group('Eid', () {
    final secret = Uint8List.fromList(List.generate(32, (i) => i));

    test('is stable within an epoch and changes across epochs', () {
      final t = DateTime.utc(2026, 9, 16, 10, 0);
      final a = Eid.current(secret, t);
      final b = Eid.current(secret, t.add(const Duration(minutes: 14)));
      final c = Eid.current(secret, t.add(const Duration(minutes: 15)));
      expect(a, b);
      expect(a, isNot(equals(c)));
      expect(a.length, 8);
    });

    test('candidates cover previous, current and next epoch', () {
      final t = DateTime.utc(2026, 9, 16, 10, 7);
      final cands = Eid.candidates(secret, t);
      expect(cands.length, 3);
      expect(cands[1], Eid.current(secret, t));
      expect(cands[2], Eid.current(secret, t.add(const Duration(minutes: 15))));
    });

    test('advertising name roundtrip', () {
      final eid = Eid.current(secret, DateTime.utc(2026));
      final name = Eid.toAdvertisingName(eid);
      expect(name.startsWith('N'), true);
      expect(name.length, 12);
      expect(Eid.fromAdvertisingName(name), eid);
      expect(Eid.fromAdvertisingName('Kopfhörer'), isNull);
      expect(Eid.fromAdvertisingName(null), isNull);
      expect(Eid.fromAdvertisingName('N!!!!'), isNull);
    });

    test('different secrets give different eids', () {
      final t = DateTime.utc(2026);
      expect(Eid.current(secret, t), isNot(equals(Eid.current(randomBytes(32), t))));
    });
  });

  group('AliasGenerator', () {
    test('is deterministic and localised', () {
      final s = Uint8List.fromList([3, 1]);
      final (de, emoji) = AliasGenerator.generate(s);
      final (en, emoji2) = AliasGenerator.generate(s, language: 'en');
      expect(de, 'Stiller Falke');
      expect(en, 'Quiet Falcon');
      expect(emoji, emoji2);
    });
  });

  group('Handshake', () {
    test('completes and both sides derive matching session keys', () async {
      final a = await DeviceIdentity.random();
      final b = await DeviceIdentity.random();

      final init = await Handshake.initiate(a);
      final resp = await Handshake.respond(b, init.msg1);
      final first = Uint8List.fromList(utf8.encode('Hi, bist du auch im Zug nach Köln?'));
      final (msg3, sessionA) = await init.finish(resp.msg2, first);
      final (sessionB, payload) = await resp.finish(msg3);

      expect(utf8.decode(payload), 'Hi, bist du auch im Zug nach Köln?');
      expect(sessionA.peerFingerprint, b.fingerprint);
      expect(sessionB.peerFingerprint, a.fingerprint);

      final replyWire = await sessionB.encrypt(Uint8List.fromList(utf8.encode('Ja!')));
      expect(utf8.decode(await sessionA.decrypt(replyWire)), 'Ja!');
      final againWire = await sessionA.encrypt(Uint8List.fromList(utf8.encode('Super')));
      expect(utf8.decode(await sessionB.decrypt(againWire)), 'Super');
    });

    test('identities never appear in cleartext on the wire', () async {
      final a = await DeviceIdentity.random();
      final b = await DeviceIdentity.random();
      final init = await Handshake.initiate(a);
      final resp = await Handshake.respond(b, init.msg1);
      final (msg3, _) = await init.finish(resp.msg2, Uint8List(0));
      for (final wire in [init.msg1, resp.msg2, msg3]) {
        expect(_contains(wire, a.signingPublicKey), false);
        expect(_contains(wire, b.signingPublicKey), false);
        expect(_contains(wire, a.staticPublicKey), false);
        expect(_contains(wire, b.staticPublicKey), false);
      }
    });

    test('tampered msg2 is rejected', () async {
      final a = await DeviceIdentity.random();
      final b = await DeviceIdentity.random();
      final init = await Handshake.initiate(a);
      final resp = await Handshake.respond(b, init.msg1);
      final bad = Uint8List.fromList(resp.msg2);
      bad[40] ^= 0xff;
      expect(() => init.finish(bad, Uint8List(0)), throwsA(isA<HandshakeException>()));
    });

    test('man in the middle replacing eB cannot impersonate B', () async {
      final a = await DeviceIdentity.random();
      final b = await DeviceIdentity.random();
      final init = await Handshake.initiate(a);
      final resp = await Handshake.respond(b, init.msg1);
      // Angreifer ersetzt Bs ephemeren Schlüssel durch einen eigenen.
      final mitm = await X25519().newKeyPair();
      final mitmPub = (await mitm.extractPublicKey()).bytes;
      final forged = Uint8List.fromList([...mitmPub, ...resp.msg2.sublist(32)]);
      expect(() => init.finish(forged, Uint8List(0)), throwsA(isA<HandshakeException>()));
    });

    test('session rejects modified ciphertext', () async {
      final a = await DeviceIdentity.random();
      final b = await DeviceIdentity.random();
      final init = await Handshake.initiate(a);
      final resp = await Handshake.respond(b, init.msg1);
      final (msg3, sessionA) = await init.finish(resp.msg2, Uint8List(0));
      final (sessionB, _) = await resp.finish(msg3);
      final wire = await sessionA.encrypt(Uint8List.fromList([1, 2, 3]));
      wire[wire.length - 1] ^= 1;
      expect(() => sessionB.decrypt(wire), throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('session serialises', () async {
      final a = await DeviceIdentity.random();
      final b = await DeviceIdentity.random();
      final init = await Handshake.initiate(a);
      final resp = await Handshake.respond(b, init.msg1);
      final (msg3, sessionA) = await init.finish(resp.msg2, Uint8List(0));
      final (sessionB, _) = await resp.finish(msg3);
      final restored = Session.deserialize(sessionA.serialize());
      final wire = await restored.encrypt(Uint8List.fromList([7]));
      expect(await sessionB.decrypt(wire), [7]);
    });
  });
}

bool _contains(Uint8List haystack, Uint8List needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
