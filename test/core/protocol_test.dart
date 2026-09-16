import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umkreis/core/protocol/cbor_codec.dart';
import 'package:umkreis/core/protocol/chunker.dart';
import 'package:umkreis/core/protocol/constants.dart';
import 'package:umkreis/core/protocol/frame.dart';
import 'package:umkreis/core/protocol/models.dart';

void main() {
  group('Frame', () {
    test('roundtrip', () {
      final f = Frame(FrameType.msg, Uint8List.fromList([1, 2, 3]));
      final bytes = f.encode();
      expect(bytes.length, 7);
      expect(bytes[0], ProtocolConstants.version);
      expect(bytes[1], 0x10);
      final back = Frame.decode(bytes);
      expect(back.type, FrameType.msg);
      expect(back.payload, [1, 2, 3]);
    });

    test('rejects wrong length field', () {
      final bytes = Frame(FrameType.ack, Uint8List(5)).encode();
      bytes[3] = 9;
      expect(() => Frame.decode(bytes), throwsA(isA<FrameFormatException>()));
    });

    test('rejects unknown type and future version', () {
      final bytes = Frame(FrameType.ack, Uint8List(0)).encode();
      bytes[1] = 0x55;
      expect(() => Frame.decode(bytes), throwsA(isA<FrameFormatException>()));
      bytes[1] = 0x11;
      bytes[0] = 9;
      expect(() => Frame.decode(bytes), throwsA(isA<UnsupportedFrameVersion>()));
    });
  });

  group('Chunker/Reassembler', () {
    test('splits and reassembles with small MTU', () {
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      final chunks = Chunker().split(data, 20);
      expect(chunks.length, (1000 / 14).ceil());
      final r = Reassembler();
      Uint8List? out;
      for (final c in chunks) {
        out = r.accept(c);
      }
      expect(out, data);
      expect(r.pendingCount, 0);
    });

    test('handles out-of-order and interleaved frames', () {
      final a = Uint8List.fromList(List.filled(100, 1));
      final b = Uint8List.fromList(List.filled(100, 2));
      final chunker = Chunker();
      final ca = chunker.split(a, 30);
      final cb = chunker.split(b, 30);
      final r = Reassembler();
      final results = <Uint8List>[];
      final order = [ca[1], cb[0], ca[0], cb[2], ca[3], ca[2], cb[1], cb[3], cb[4], ca[4]];
      for (final c in order) {
        final out = r.accept(c);
        if (out != null) results.add(out);
      }
      expect(results.length, 2);
      expect(results, containsAll([a, b]));
    });

    test('drops stale partial frames', () {
      var now = DateTime(2026, 1, 1);
      final r = Reassembler(clock: () => now);
      final chunks = Chunker().split(Uint8List(50), 20);
      r.accept(chunks[0]);
      expect(r.pendingCount, 1);
      now = now.add(const Duration(seconds: 10));
      r.accept(Chunker(startId: 500).split(Uint8List(5), 20).single);
      expect(r.pendingCount, 0);
    });

    test('empty frame produces one chunk', () {
      final chunks = Chunker().split(Uint8List(0), 20);
      expect(chunks.length, 1);
      expect(Reassembler().accept(chunks.single), Uint8List(0));
    });
  });

  group('CborCodec', () {
    test('roundtrip of all supported types', () {
      final m = <String, Object?>{
        'i': 42,
        'neg': -7,
        's': 'Grüner Falke 🦅',
        'b': true,
        'n': null,
        'f': 1.5,
        'bytes': Uint8List.fromList([0, 255, 7]),
        'list': [1, 'x', Uint8List.fromList([9])],
        'map': {'k': 'v'},
      };
      final back = CborCodec.decode(CborCodec.encode(m));
      expect(back['i'], 42);
      expect(back['neg'], -7);
      expect(back['s'], 'Grüner Falke 🦅');
      expect(back['b'], true);
      expect(back['n'], isNull);
      expect(back['f'], 1.5);
      expect(back.bytes('bytes'), [0, 255, 7]);
      expect((back['list'] as List)[0], 1);
      expect(back.submap('map')!['k'], 'v');
    });
  });

  group('Models', () {
    test('Presence roundtrip', () {
      final p = Presence(
        mode: VisibilityMode.profile,
        alias: 'Blauer Otter',
        emoji: '🦦',
        status: 'Suche Mitfahrer',
        hasProfile: true,
        eid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      );
      final back = Presence.decode(p.encode());
      expect(back.mode, VisibilityMode.profile);
      expect(back.alias, 'Blauer Otter');
      expect(back.hasProfile, true);
      expect(back.eid, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(p.encode().length, lessThan(180));
    });

    test('Post roundtrip and expiry', () {
      final post = Post(
        id: 'ab' * 16,
        timestamp: DateTime(2026, 1, 1, 12),
        ttl: const Duration(hours: 1),
        alias: 'A',
        emoji: '🦊',
        tag: 'hilfe',
        text: 'Hallo',
        signature: Uint8List(64),
        publicKey: Uint8List(32),
      );
      final back = Post.decode(post.encode());
      expect(back.id, post.id);
      expect(back.tag, 'hilfe');
      expect(back.isExpired(DateTime(2026, 1, 1, 12, 59)), false);
      expect(back.isExpired(DateTime(2026, 1, 1, 13)), true);
      expect(back.replyTo, isNull);
    });
  });
}
