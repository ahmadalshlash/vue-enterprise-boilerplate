import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart';

import '../ble/transport.dart';
import '../crypto/eid.dart';
import '../crypto/handshake.dart';
import '../crypto/random.dart';
import '../crypto/session.dart';
import '../moderation/block_service.dart';
import '../protocol/cbor_codec.dart';
import '../protocol/constants.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../storage/app_database.dart';
import 'identity_service.dart';
import 'radar_service.dart';

/// Ein Chat mit einer Person (Schlüssel: Geräte-Fingerabdruck).
class Chat {
  Chat(this.stored, this.session);

  final StoredChat stored;
  Session? session;
  final List<StoredMessage> messages = [];

  /// Letzte Transport-Kennung, über die der Peer erreichbar war.
  PeerId? route;

  String get fingerprint => stored.fingerprint;
  String get alias => stored.revealedProfile?.name ?? stored.alias;
  String get emoji => stored.revealedProfile?.emoji ?? stored.emoji;
  ChatState get state => stored.state;
  int get unread => stored.unread;
  /// Nachrichten, die in der UI erscheinen (ohne Steuer-Nachrichten).
  List<StoredMessage> get visibleMessages =>
      messages.where((m) => m.kind == MessageKind.text || m.kind == MessageKind.reveal).toList();
  StoredMessage? get lastMessage => visibleMessages.isEmpty ? null : visibleMessages.last;
  bool get hasPending => messages.any((m) => m.outgoing && m.status == MessageStatus.pending);
}

/// Kontaktanfragen, 1:1-Chats, Zustellung, Store-and-Forward.
class ChatService extends ChangeNotifier {
  ChatService({
    required NearbyTransport transport,
    required IdentityService identity,
    required RadarService radar,
    required BlockService blocks,
    required ChatRepository repo,
    DateTime Function()? clock,
  })  : _transport = transport,
        _identity = identity,
        _radar = radar,
        _blocks = blocks,
        _repo = repo,
        _clock = clock ?? DateTime.now;

  final NearbyTransport _transport;
  final IdentityService _identity;
  final RadarService _radar;
  final BlockService _blocks;
  final ChatRepository _repo;
  final DateTime Function() _clock;

  final Map<String, Chat> _chats = {};
  final Map<PeerId, _PendingInitiator> _initiators = {};
  final Map<PeerId, HandshakeResponder> _responders = {};
  Timer? _flushTimer;

  /// Neue eingehende Anfrage (für Benachrichtigungen).
  final StreamController<Chat> _incoming = StreamController.broadcast();
  Stream<Chat> get incomingRequests => _incoming.stream;

  List<Chat> get requests => _chats.values.where((c) => c.state == ChatState.incomingRequest).toList()
    ..sort((a, b) => b.stored.updatedAt.compareTo(a.stored.updatedAt));

  List<Chat> get active => _chats.values
      .where((c) => c.state == ChatState.active || c.state == ChatState.outgoingPending)
      .toList()
    ..sort((a, b) => b.stored.updatedAt.compareTo(a.stored.updatedAt));

  int get unreadTotal => _chats.values.fold(0, (n, c) => n + c.unread) + requests.length;

  Chat? byFingerprint(String fp) => _chats[fp];

  Future<void> load() async {
    for (final sc in await _repo.allChats()) {
      final chat = Chat(sc, sc.session == null ? null : Session.deserialize(sc.session!));
      _chats[sc.fingerprint] = chat;
    }
    for (final m in await _repo.allMessages()) {
      _chats[m.chatFingerprint]?.messages.add(m);
    }
    notifyListeners();
  }

  void start() {
    _flushTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => flushOutbox());
  }

  void stop() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  // ---------------------------------------------------------------- Ausgehend

  /// Kontaktanfrage an einen Radar-Peer: startet den Handshake, die erste
  /// Nachricht reist in msg3 mit.
  Future<void> sendRequest(RadarPeer peer, String text) async {
    final t = text.trim();
    if (t.isEmpty) throw ArgumentError('Leere Nachricht');
    if (_initiators.containsKey(peer.peerId)) return;
    final init = await Handshake.initiate(_identity.identity);
    _initiators[peer.peerId] = _PendingInitiator(init, t, peer.displayName, peer.emoji, _clock());
    try {
      await _transport.send(peer.peerId, Frame(FrameType.hello, init.msg1).encode());
    } catch (e) {
      _initiators.remove(peer.peerId);
      throw TransportException('Anfrage konnte nicht gesendet werden', e);
    }
    _expirePending();
  }

  void _expirePending() {
    final now = _clock();
    _initiators.removeWhere((_, p) => now.difference(p.startedAt) > const Duration(minutes: 2));
  }

  /// Nachricht in einem aktiven Chat. Ohne Route bleibt sie „wartet auf Nähe“.
  Future<StoredMessage> sendMessage(String fingerprint, String text, {MessageKind kind = MessageKind.text}) async {
    final chat = _chats[fingerprint];
    if (chat == null || chat.session == null) throw StateError('Kein aktiver Chat');
    if (chat.state == ChatState.blocked) throw StateError('Blockiert');
    var body = text.trim();
    if (kind == MessageKind.text) {
      if (body.isEmpty) throw ArgumentError('Leere Nachricht');
      if (body.length > ProtocolConstants.maxMessageChars) {
        body = body.substring(0, ProtocolConstants.maxMessageChars);
      }
    }
    final msg = StoredMessage(
      id: randomId(),
      chatFingerprint: fingerprint,
      timestamp: _clock(),
      kind: kind,
      body: body,
      outgoing: true,
      status: MessageStatus.pending,
    );
    chat.messages.add(msg);
    chat.stored.updatedAt = msg.timestamp;
    await _repo.upsertMessage(msg);
    await _repo.upsertChat(chat.stored);
    notifyListeners();
    await _deliver(chat, msg);
    return msg;
  }

  /// Eigenes Profil im Chat aufdecken.
  Future<void> reveal(String fingerprint) async {
    final p = _identity.profile;
    if (p == null) throw StateError('Kein Profil');
    final signed = await _identity.signProfile(p);
    await sendMessage(fingerprint, base64Encode(signed), kind: MessageKind.reveal);
  }

  Future<void> _deliver(Chat chat, StoredMessage msg) async {
    final route = _routeFor(chat);
    if (route == null) return;
    final payload = ChatPayload(id: msg.id, timestamp: msg.timestamp, kind: msg.kind, body: msg.body).encode();
    try {
      final wire = await chat.session!.encrypt(payload);
      await _transport.send(route, Frame(FrameType.msg, wire).encode());
      msg.status = MessageStatus.sent;
      chat.route = route;
      await _repo.upsertMessage(msg);
      notifyListeners();
    } catch (e) {
      debugPrint('Chat: Zustellung an ${chat.fingerprint} fehlgeschlagen: $e');
      if (chat.route == route) chat.route = null;
    }
  }

  PeerId? _routeFor(Chat chat) {
    // 1) Bekannte Route, solange der Peer noch im Radar ist bzw. als Central verbunden war.
    final r = chat.route;
    if (r != null && (r.startsWith('c:') || _radar.byPeerId(r) != null)) return r;
    // 2) Über die EID-Kette des Kontakts.
    final secret = chat.stored.peerAliasSecret;
    if (secret != null) {
      final peer = _radar.byEidCandidates(Eid.candidates(secret, _clock()));
      if (peer != null) return peer.peerId;
    }
    return null;
  }

  /// Versucht, wartende Nachrichten zuzustellen (periodisch und bei Bedarf).
  Future<void> flushOutbox() async {
    _expirePending();
    final cutoff = _clock().subtract(ProtocolConstants.outboxLifetime);
    for (final chat in _chats.values) {
      if (chat.session == null || chat.state != ChatState.active) continue;
      for (final m in List.of(chat.messages)) {
        if (!m.outgoing || m.status != MessageStatus.pending) continue;
        if (m.timestamp.isBefore(cutoff)) continue;
        await _deliver(chat, m);
      }
    }
  }

  // ---------------------------------------------------------------- Eingehend

  /// Einstiegspunkt für alle Chat-Frames vom Transport.
  Future<void> handleFrame(PeerId from, Frame frame) async {
    try {
      switch (frame.type) {
        case FrameType.hello:
          await _onHello(from, frame.payload);
        case FrameType.handshake:
          await _onHandshake(from, frame.payload);
        case FrameType.msg:
          await _onMsg(from, frame.payload);
        case FrameType.ack:
          await _onAck(from, frame.payload);
        case FrameType.reveal:
          await _onMsg(from, frame.payload);
        default:
          break;
      }
    } on HandshakeException catch (e) {
      debugPrint('Chat: Handshake mit $from abgebrochen: $e');
      _initiators.remove(from);
      _responders.remove(from);
    } catch (e) {
      debugPrint('Chat: Fehler bei Frame ${frame.type} von $from: $e');
    }
  }

  Future<void> _onHello(PeerId from, Uint8List msg1) async {
    if (!_identity.isVisible) return; // Unsichtbar: keine Anfragen annehmen.
    final resp = await Handshake.respond(_identity.identity, msg1);
    _responders[from] = resp;
    await _transport.send(from, Frame(FrameType.handshake, CborCodec.encode({'step': 2, 'data': resp.msg2})).encode());
  }

  Future<void> _onHandshake(PeerId from, Uint8List payload) async {
    final m = CborCodec.decode(payload);
    final step = m.integer('step');
    final data = m.bytes('data');
    if (data == null) return;
    if (step == 2) {
      final pending = _initiators.remove(from);
      if (pending == null) return;
      final first = ChatPayload(id: randomId(), timestamp: _clock(), body: pending.text);
      final (msg3, session) = await pending.initiator.finish(data, first.encode());
      if (_blocks.isFingerprintBlocked(session.peerFingerprint)) return;
      await _transport.send(from, Frame(FrameType.handshake, CborCodec.encode({'step': 3, 'data': msg3})).encode());
      final chat = await _upsertChat(
        session,
        alias: pending.alias,
        emoji: pending.emoji,
        state: ChatState.active,
        route: from,
      );
      final msg = StoredMessage(
        id: first.id,
        chatFingerprint: chat.fingerprint,
        timestamp: first.timestamp,
        kind: MessageKind.text,
        body: pending.text,
        outgoing: true,
        status: MessageStatus.sent,
      );
      chat.messages.add(msg);
      await _repo.upsertMessage(msg);
      await _sendContactKey(chat);
      notifyListeners();
    } else if (step == 3) {
      final resp = _responders.remove(from);
      if (resp == null) return;
      final (session, payload) = await resp.finish(data);
      if (_blocks.isFingerprintBlocked(session.peerFingerprint)) {
        await _transport.drop(from);
        return;
      }
      final first = ChatPayload.decode(payload);
      final existing = _chats[session.peerFingerprint];
      final chat = await _upsertChat(
        session,
        alias: existing?.stored.alias ?? _peerAlias(from),
        emoji: existing?.stored.emoji ?? _peerEmoji(from),
        state: existing?.state == ChatState.active ? ChatState.active : ChatState.incomingRequest,
        route: from,
      );
      await _storeIncoming(chat, first);
      if (chat.state == ChatState.incomingRequest) _incoming.add(chat);
      notifyListeners();
      await _ack(chat, [first.id]);
    }
  }

  String _peerAlias(PeerId from) => _radar.byPeerId(from)?.displayName ?? '';
  String _peerEmoji(PeerId from) => _radar.byPeerId(from)?.emoji ?? '👤';

  Future<Chat> _upsertChat(
    Session session, {
    required String alias,
    required String emoji,
    required ChatState state,
    required PeerId route,
  }) async {
    final fp = session.peerFingerprint;
    var chat = _chats[fp];
    final now = _clock();
    if (chat == null) {
      final stored = StoredChat(
        fingerprint: fp,
        alias: alias.isEmpty ? '?' : alias,
        emoji: emoji,
        state: state,
        session: session.serialize(),
        createdAt: now,
        updatedAt: now,
      );
      chat = Chat(stored, session);
      _chats[fp] = chat;
    } else {
      chat.session = session;
      chat.stored.session = session.serialize();
      if (alias.isNotEmpty) chat.stored.alias = alias;
      if (emoji.isNotEmpty) chat.stored.emoji = emoji;
      if (chat.stored.state == ChatState.rejected) chat.stored.state = ChatState.incomingRequest;
      chat.stored.updatedAt = now;
    }
    chat.route = route;
    await _repo.upsertChat(chat.stored);
    return chat;
  }

  Future<void> _onMsg(PeerId from, Uint8List wire) async {
    // Wir wissen nicht, von welchem Chat das Frame kommt → Session über die
    // Route finden, sonst alle Sessions probieren (AEAD schlägt bei falschem Schlüssel fehl).
    final candidates = <Chat>[
      ..._chats.values.where((c) => c.route == from && c.session != null),
      ..._chats.values.where((c) => c.route != from && c.session != null),
    ];
    for (final chat in candidates) {
      Uint8List clear;
      try {
        clear = await chat.session!.decrypt(wire);
      } on SecretBoxAuthenticationError {
        continue;
      }
      if (chat.state == ChatState.blocked) return;
      chat.route = from;
      final payload = ChatPayload.decode(clear);
      if (payload.kind == MessageKind.ack) {
        await _applyAck(chat, CborCodec.decode(Uint8List.fromList(base64Decode(payload.body))).list('ids'));
        return;
      }
      await _storeIncoming(chat, payload);
      await _ack(chat, [payload.id]);
      notifyListeners();
      return;
    }
    debugPrint('Chat: MSG von $from passt zu keiner Session');
  }

  Future<void> _storeIncoming(Chat chat, ChatPayload p) async {
    if (chat.messages.any((m) => m.id == p.id)) return;
    switch (p.kind) {
      case MessageKind.reveal:
        final verified = await IdentityService.verifySignedProfile(Uint8List.fromList(base64Decode(p.body)));
        if (verified != null && verified.$2 == chat.fingerprint) {
          chat.stored.revealedProfile = verified.$1;
        }
      case MessageKind.contactKey:
        try {
          final map = CborCodec.decode(Uint8List.fromList(base64Decode(p.body)));
          final secret = map.bytes('aliasSecret');
          if (secret != null && secret.length == 32) {
            chat.stored.peerAliasSecret = secret;
            await _repo.upsertChat(chat.stored);
          }
        } catch (_) {}
        return;
      case MessageKind.ack:
        return;
      default:
        break;
    }
    if (p.kind == MessageKind.text && p.body.isEmpty) return;
    final msg = StoredMessage(
      id: p.id,
      chatFingerprint: chat.fingerprint,
      timestamp: p.timestamp,
      kind: p.kind,
      body: p.kind == MessageKind.reveal ? '' : p.body,
      outgoing: false,
      status: MessageStatus.received,
    );
    chat.messages.add(msg);
    chat.stored.updatedAt = _clock();
    chat.stored.unread += 1;
    await _repo.upsertMessage(msg);
    await _repo.upsertChat(chat.stored);
  }

  Future<void> _ack(Chat chat, List<String> ids) async {
    final route = chat.route;
    if (route == null || chat.session == null) return;
    final body = base64Encode(CborCodec.encode({'ids': ids}));
    final payload = ChatPayload(id: randomId(8), timestamp: _clock(), kind: MessageKind.ack, body: body).encode();
    try {
      final wire = await chat.session!.encrypt(payload);
      await _transport.send(route, Frame(FrameType.ack, wire).encode());
    } catch (e) {
      debugPrint('Chat: ACK an ${chat.fingerprint} fehlgeschlagen: $e');
    }
  }

  Future<void> _onAck(PeerId from, Uint8List wire) => _onMsg(from, wire);

  Future<void> _applyAck(Chat chat, List<Object?> ids) async {
    var changed = false;
    for (final id in ids.whereType<String>()) {
      final m = chat.messages.where((m) => m.id == id && m.outgoing).firstOrNull;
      if (m != null && m.status != MessageStatus.delivered) {
        m.status = MessageStatus.delivered;
        await _repo.upsertMessage(m);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Schickt dem Kontakt mein Alias-Secret (verschlüsselt), damit er meine
  /// EIDs wiedererkennt. Auch nach jeder Alias-Rotation aufrufen.
  Future<void> _sendContactKey(Chat chat) async {
    await sendMessage(chat.fingerprint, base64Encode(_identity.contactKeyBytes()), kind: MessageKind.contactKey);
  }

  /// Nach Alias-Rotation: alle aktiven Kontakte informieren.
  Future<void> broadcastContactKey() async {
    for (final chat in _chats.values.where((c) => c.state == ChatState.active && c.session != null)) {
      await _sendContactKey(chat);
    }
  }

  // ------------------------------------------------------------- Anfragen/UI

  Future<void> accept(String fingerprint) async {
    final chat = _chats[fingerprint];
    if (chat == null) return;
    chat.stored.state = ChatState.active;
    chat.stored.updatedAt = _clock();
    await _repo.upsertChat(chat.stored);
    notifyListeners();
    await _sendContactKey(chat);
  }

  Future<void> reject(String fingerprint) async {
    final chat = _chats[fingerprint];
    if (chat == null) return;
    chat.stored.state = ChatState.rejected;
    await _repo.upsertChat(chat.stored);
    notifyListeners();
  }

  Future<void> block(String fingerprint) async {
    final chat = _chats[fingerprint];
    await _blocks.blockFingerprint(fingerprint, label: chat?.alias ?? '');
    if (chat != null) {
      chat.stored.state = ChatState.blocked;
      await _repo.upsertChat(chat.stored);
      final r = chat.route;
      if (r != null) await _transport.drop(r);
      chat.route = null;
    }
    notifyListeners();
  }

  Future<void> delete(String fingerprint) async {
    _chats.remove(fingerprint);
    await _repo.deleteChat(fingerprint);
    notifyListeners();
  }

  Future<void> markRead(String fingerprint) async {
    final chat = _chats[fingerprint];
    if (chat == null || chat.unread == 0) return;
    chat.stored.unread = 0;
    await _repo.upsertChat(chat.stored);
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _incoming.close();
    super.dispose();
  }
}

class _PendingInitiator {
  _PendingInitiator(this.initiator, this.text, this.alias, this.emoji, this.startedAt);
  final HandshakeInitiator initiator;
  final String text;
  final String alias;
  final String emoji;
  final DateTime startedAt;
}
