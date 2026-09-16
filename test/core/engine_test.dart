import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umkreis/core/ble/fake_transport.dart';
import 'package:umkreis/core/ble/rssi.dart';
import 'package:umkreis/core/crypto/key_store.dart';
import 'package:umkreis/core/protocol/models.dart';
import 'package:umkreis/core/services/engine.dart';
import 'package:umkreis/core/storage/app_database.dart';

/// Zwei (oder mehr) komplette Engines reden über die FakeWorld miteinander.
/// Das ist der End-to-End-Test der gesamten Logik ohne echtes Bluetooth.
void main() {
  late FakeWorld world;

  Future<Engine> makeEngine(String id, {double x = 0, double y = 0}) async {
    final transport = world.createNode(id, x: x, y: y);
    final engine = await Engine.create(
      transport: transport,
      db: await AppDatabase.openMemory(),
      keyStore: InMemoryKeyStore(),
    );
    await engine.identity.completeOnboarding();
    await engine.start();
    return engine;
  }

  /// Wartet, bis [condition] wahr ist; treibt dabei die Funkwelt an.
  Future<void> waitFor(bool Function() condition, {int ticks = 40}) async {
    for (var i = 0; i < ticks; i++) {
      if (condition()) return;
      world.broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), true, reason: 'Bedingung nicht innerhalb $ticks Ticks erfüllt');
  }

  setUp(() {
    world = FakeWorld(fakeMtu: 50);
  });

  test('two devices discover each other with proximity', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 3);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);
    final peer = a.radar.resolvedPeers.single;
    expect(peer.displayName, b.identity.alias);
    expect(peer.emoji, b.identity.emoji);
    expect(peer.proximity, Proximity.veryNear);

    world.moveTo('b', 60, 0);
    await waitFor(() => a.radar.resolvedPeers.single.proximity == Proximity.inRange, ticks: 12);
    await a.stop();
    await b.stop();
  });

  test('invisible devices are not shown but still see others', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 2);
    await b.identity.setMode(VisibilityMode.invisible);
    for (var i = 0; i < 5; i++) {
      world.broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(a.radar.count, 0);
    expect(b.radar.count, 1);
    await a.stop();
    await b.stop();
  });

  test('contact request, accept, encrypted chat in both directions', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);

    final incoming = <String>[];
    final sub = b.chats.incomingRequests.listen((c) => incoming.add(c.fingerprint));

    await a.chats.sendRequest(a.radar.resolvedPeers.single, 'Hi, bist du auch im Zug nach Köln?');
    await waitFor(() => b.chats.requests.length == 1 && incoming.isNotEmpty);
    expect(incoming, [a.identity.identity.fingerprint]);

    final request = b.chats.requests.single;
    expect(request.fingerprint, a.identity.identity.fingerprint);
    expect(request.alias, a.identity.alias);
    expect(request.visibleMessages.single.body, 'Hi, bist du auch im Zug nach Köln?');

    // A sieht den Chat als aktiv, erste Nachricht als zugestellt (ACK).
    await waitFor(() => a.chats.active.length == 1);
    final chatA = a.chats.active.single;
    expect(chatA.fingerprint, b.identity.identity.fingerprint);
    await waitFor(() => chatA.visibleMessages.single.status == MessageStatus.delivered);

    await b.chats.accept(request.fingerprint);
    expect(b.chats.active.single.state, ChatState.active);
    // Kontakt-Schlüssel wurde ausgetauscht (für Wiedererkennung über EIDs).
    await waitFor(() => chatA.stored.peerAliasSecret != null && request.stored.peerAliasSecret != null);

    await b.chats.sendMessage(request.fingerprint, 'Ja! Wagen 7.');
    await waitFor(() => chatA.visibleMessages.length == 2);
    expect(chatA.visibleMessages.last.body, 'Ja! Wagen 7.');
    expect(chatA.visibleMessages.last.outgoing, false);
    expect(chatA.unread, 1);

    // Im Funk steht nichts im Klartext.
    final transportA = a.transport as FakeTransport;
    final transportB = b.transport as FakeTransport;
    for (final (_, bytes) in [...transportA.sent, ...transportB.sent]) {
      final s = String.fromCharCodes(bytes);
      expect(s.contains('Köln'), false);
      expect(s.contains('Wagen 7'), false);
    }

    await sub.cancel();
    await a.stop();
    await b.stop();
  });

  test('messages wait for proximity and are delivered when the peer returns', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);
    await a.chats.sendRequest(a.radar.resolvedPeers.single, 'Hallo');
    await waitFor(() => b.chats.requests.length == 1);
    await b.chats.accept(b.chats.requests.single.fingerprint);
    final chatA = a.chats.active.single;
    await waitFor(() => chatA.stored.peerAliasSecret != null);

    // B geht außer Reichweite; Radar-Timeout ist 20 s, wir simulieren das Vergessen.
    world.moveTo('b', 500, 0);
    a.radar.forget('f:b');
    chatA.route = null;
    final msg = await a.chats.sendMessage(chatA.fingerprint, 'Bist du noch da?');
    expect(msg.status, MessageStatus.pending);

    // B kommt zurück: Radar sieht neue Sichtung, Outbox wird geleert.
    world.moveTo('b', 4, 0);
    await waitFor(() => a.radar.count == 1);
    await a.chats.flushOutbox();
    await waitFor(() => msg.status != MessageStatus.pending);
    final chatB = b.chats.active.single;
    await waitFor(() => chatB.visibleMessages.any((m) => m.body == 'Bist du noch da?'));
    await a.stop();
    await b.stop();
  });

  test('blocked device cannot start a chat', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);
    await b.blocks.blockFingerprint(a.identity.identity.fingerprint);
    await a.chats.sendRequest(a.radar.resolvedPeers.single, 'Hallo?');
    for (var i = 0; i < 10; i++) {
      world.broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(b.chats.requests, isEmpty);
    expect(b.chats.active, isEmpty);
    await a.stop();
    await b.stop();
  });

  test('board posts spread to peers in range and sync to newcomers', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);

    await a.board.createPost(text: 'Suche Mitfahrer nach Köln', tag: 'mitfahren');
    await waitFor(() => b.board.posts.length == 1);
    final received = b.board.posts.single;
    expect(received.post.text, 'Suche Mitfahrer nach Köln');
    expect(received.post.alias, a.identity.alias);
    expect(received.mine, false);
    expect(a.board.posts.single.mine, true);

    await b.board.react(received.post.id, '👍');
    await waitFor(() => (a.board.posts.single.reactions['👍'] ?? 0) == 1);

    // C kommt später dazu und bekommt den Post per Sync.
    final c = await makeEngine('c', x: 2, y: 2);
    await waitFor(() => c.board.posts.length == 1, ticks: 60);
    expect(c.board.posts.single.post.id, received.post.id);

    await a.stop();
    await b.stop();
    await c.stop();
  });

  test('board rejects forged posts and filters flagged words', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);

    // Gefälschter Post: Text nach dem Signieren geändert.
    final real = await a.board.createPost(text: 'Original');
    await waitFor(() => b.board.posts.length == 1);
    final forged = Post(
      id: 'ff' * 16,
      timestamp: real.timestamp,
      ttl: real.ttl,
      alias: real.alias,
      emoji: real.emoji,
      tag: real.tag,
      text: 'Gefälscht',
      signature: real.signature,
      publicKey: real.publicKey,
    );
    final tA = a.transport as FakeTransport;
    await tA.send('f:b', _postFrame(forged));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(b.board.posts.length, 1);

    await a.board.createPost(text: 'Du Hurensohn');
    await waitFor(() => b.board.totalCount == 2);
    expect(b.board.posts.length, 1, reason: 'beleidigender Post wird ausgeblendet');
    b.board.showHidden = true;
    expect(b.board.posts.length, 2);

    await a.stop();
    await b.stop();
  });

  test('block author hides all posts of that key', () async {
    final a = await makeEngine('a');
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);
    await a.board.createPost(text: 'eins');
    await a.board.createPost(text: 'zwei');
    await waitFor(() => b.board.posts.length == 2);
    await b.board.blockAuthor(b.board.posts.first.post.id);
    expect(b.board.posts, isEmpty);
    await a.board.createPost(text: 'drei');
    for (var i = 0; i < 5; i++) {
      world.broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(b.board.posts, isEmpty);
    expect(b.blocks.entries.length, 1);
    await a.stop();
    await b.stop();
  });

  test('state survives restart from the same database', () async {
    final db = await AppDatabase.openMemory();
    final keys = InMemoryKeyStore();
    final tA = world.createNode('a');
    var a = await Engine.create(transport: tA, db: db, keyStore: keys);
    await a.start();
    final b = await makeEngine('b', x: 5);
    await waitFor(() => a.radar.count == 1 && b.radar.count == 1);
    await a.chats.sendRequest(a.radar.resolvedPeers.single, 'Hallo');
    await waitFor(() => b.chats.requests.length == 1);
    await b.chats.accept(b.chats.requests.single.fingerprint);
    await b.chats.sendMessage(b.chats.active.single.fingerprint, 'Zurück');
    await waitFor(() => a.chats.active.single.visibleMessages.length == 2);
    final alias = a.identity.alias;
    final fp = a.identity.identity.fingerprint;
    await a.stop();

    a = await Engine.create(transport: tA, db: db, keyStore: keys);
    expect(a.identity.alias, alias);
    expect(a.identity.identity.fingerprint, fp);
    expect(a.chats.active.single.visibleMessages.length, 2);
    expect(a.chats.active.single.session, isNotNull);
    await b.stop();
  });
}

Uint8List _postFrame(Post p) {
  final payload = p.encode();
  final out = Uint8List(4 + payload.length);
  out[0] = 1;
  out[1] = 0x20;
  out[2] = payload.length >> 8;
  out[3] = payload.length & 0xff;
  out.setRange(4, out.length, payload);
  return out;
}
