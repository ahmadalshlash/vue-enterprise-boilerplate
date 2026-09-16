import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/transport.dart';
import '../crypto/identity.dart';
import '../crypto/random.dart';
import '../moderation/block_service.dart';
import '../moderation/rate_limiter.dart';
import '../moderation/word_filter.dart';
import '../protocol/cbor_codec.dart';
import '../protocol/constants.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../storage/app_database.dart';
import 'identity_service.dart';
import 'radar_service.dart';

/// Vorgeschlagene Tags.
const boardTags = ['hilfe', 'mitfahren', 'verloren', 'party', 'frage', 'notfall', 'sonstiges'];

/// Post mit lokalem Zustand.
class BoardPost {
  BoardPost(this.post, {this.hidden = false, this.mine = false});
  final Post post;
  bool hidden;
  final bool mine;
  final Map<String, int> reactions = {};
  final Set<String> myReactions = {};
  String get authorKeyHex => bytesToHex(post.publicKey);
}

/// Lokales Schwarzes Brett: eigene Posts, Empfang, Verifikation, Sync
/// mit Peers in Reichweite (MVP: keine Mesh-Weiterleitung).
class BoardService extends ChangeNotifier {
  BoardService({
    required NearbyTransport transport,
    required IdentityService identity,
    required RadarService radar,
    required BlockService blocks,
    required PostRepository repo,
    WordFilter? wordFilter,
    DateTime Function()? clock,
  })  : _transport = transport,
        _identity = identity,
        _radar = radar,
        _blocks = blocks,
        _repo = repo,
        _filter = wordFilter ?? WordFilter(),
        _clock = clock ?? DateTime.now,
        _rate = RateLimiter(
          limit: ProtocolConstants.postsPerWindow,
          window: ProtocolConstants.postWindow,
          clock: clock,
        );

  final NearbyTransport _transport;
  final IdentityService _identity;
  final RadarService _radar;
  final BlockService _blocks;
  final PostRepository _repo;
  final WordFilter _filter;
  final DateTime Function() _clock;
  final RateLimiter _rate;

  final Map<String, BoardPost> _posts = {};
  final Set<String> _myKeys = {};
  Timer? _timer;
  String? tagFilter;
  bool showHidden = false;

  /// Zum Testen/Debuggen: alle je empfangenen Post-IDs.
  int get totalCount => _posts.length;

  List<BoardPost> get posts {
    final now = _clock();
    final list = _posts.values
        .where((p) => !p.post.isExpired(now))
        .where((p) => showHidden || !p.hidden)
        .where((p) => p.post.replyTo == null)
        .where((p) => tagFilter == null || p.post.tag == tagFilter)
        .toList()
      ..sort((a, b) => b.post.timestamp.compareTo(a.post.timestamp));
    return list;
  }

  List<BoardPost> repliesTo(String postId) => _posts.values
      .where((p) => p.post.replyTo == postId && !p.hidden)
      .toList()
    ..sort((a, b) => a.post.timestamp.compareTo(b.post.timestamp));

  BoardPost? byId(String id) => _posts[id];

  Future<void> load() async {
    await _repo.deleteExpired(_clock());
    _refreshMyKeys();
    for (final (post, hidden) in await _repo.all()) {
      _posts[post.id] = BoardPost(post, hidden: hidden, mine: _myKeys.contains(bytesToHex(post.publicKey)));
    }
    final counts = await _repo.reactionCounts();
    for (final e in counts.entries) {
      _posts[e.key]?.reactions.addAll(e.value);
    }
    notifyListeners();
  }

  void _refreshMyKeys() {
    _myKeys
      ..add(bytesToHex(_identity.identity.signingPublicKey))
      ..add(bytesToHex(_identity.posterPublicKey(asProfile: false)));
  }

  void start() {
    _radar.onPeerResolved.add(_onPeerResolved);
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => _cleanup());
  }

  void stop() {
    _radar.onPeerResolved.remove(_onPeerResolved);
    _timer?.cancel();
    _timer = null;
  }

  void setTagFilter(String? tag) {
    tagFilter = tag;
    notifyListeners();
  }

  // -------------------------------------------------------------------- Eigene

  Future<Post> createPost({
    required String text,
    String tag = 'sonstiges',
    Duration? ttl,
    bool asProfile = false,
    String? replyTo,
  }) async {
    var t = text.trim();
    if (t.isEmpty) throw ArgumentError('Leerer Post');
    if (t.length > ProtocolConstants.maxPostChars) t = t.substring(0, ProtocolConstants.maxPostChars);
    final useProfile = asProfile && _identity.hasProfile;
    _refreshMyKeys();
    final draft = Post(
      id: randomId(),
      timestamp: _clock(),
      ttl: ttl ?? ProtocolConstants.defaultPostTtl,
      alias: useProfile ? _identity.profile!.name : _identity.alias,
      emoji: useProfile ? _identity.profile!.emoji : _identity.emoji,
      tag: tag,
      text: t,
      replyTo: replyTo,
      signature: Uint8List(0),
      publicKey: _identity.posterPublicKey(asProfile: useProfile),
      isProfilePost: useProfile,
    );
    final sig = await _identity.signAsPoster(draft.signedBytes(), asProfile: useProfile);
    final post = Post(
      id: draft.id,
      timestamp: draft.timestamp,
      ttl: draft.ttl,
      alias: draft.alias,
      emoji: draft.emoji,
      tag: draft.tag,
      text: draft.text,
      replyTo: draft.replyTo,
      signature: sig,
      publicKey: draft.publicKey,
      isProfilePost: useProfile,
    );
    _posts[post.id] = BoardPost(post, mine: true);
    await _repo.upsert(post);
    notifyListeners();
    await _pushToAll(Frame(FrameType.post, post.encode()).encode());
    return post;
  }

  Future<void> react(String postId, String reaction) async {
    final bp = _posts[postId];
    if (bp == null || bp.myReactions.contains(reaction)) return;
    final pub = _identity.posterPublicKey(asProfile: false);
    final r = PostReaction(postId: postId, reaction: reaction, signature: Uint8List(0), publicKey: pub);
    final sig = await _identity.signAsPoster(r.signedBytes(), asProfile: false);
    final signed = PostReaction(postId: postId, reaction: reaction, signature: sig, publicKey: pub);
    bp.myReactions.add(reaction);
    bp.reactions[reaction] = (bp.reactions[reaction] ?? 0) + 1;
    await _repo.putReaction(postId, bytesToHex(pub), reaction);
    notifyListeners();
    await _pushToAll(Frame(FrameType.postReact, signed.encode()).encode());
  }

  Future<void> _pushToAll(Uint8List frameBytes) async {
    for (final peer in _radar.resolvedPeers) {
      try {
        await _transport.send(peer.peerId, frameBytes);
      } catch (e) {
        debugPrint('Board: Push an ${peer.peerId} fehlgeschlagen: $e');
      }
    }
  }

  // ----------------------------------------------------------------- Empfang

  /// Frames vom Transport.
  Future<void> handleFrame(PeerId from, Frame frame) async {
    try {
      switch (frame.type) {
        case FrameType.post:
          await _onPost(Post.decode(frame.payload));
        case FrameType.postReact:
          await _onReaction(PostReaction.decode(frame.payload));
        case FrameType.postSyncReq:
          await _onSyncRequest(from, CborCodec.decode(frame.payload));
        default:
          break;
      }
    } catch (e) {
      debugPrint('Board: Fehler bei ${frame.type} von $from: $e');
    }
  }

  Future<bool> _onPost(Post post) async {
    if (post.id.length != 32 || post.text.isEmpty) return false;
    if (post.text.length > ProtocolConstants.maxPostChars) return false;
    if (post.isExpired(_clock())) return false;
    if (post.ttl > const Duration(hours: 24)) return false;
    if (_posts.containsKey(post.id)) return false;
    final keyHex = bytesToHex(post.publicKey);
    if (_blocks.isPostKeyBlocked(keyHex)) return false;
    if (post.isProfilePost && _blocks.isFingerprintBlocked(DeviceIdentity.fingerprintOf(post.publicKey))) {
      return false;
    }
    if (!await DeviceIdentity.verify(post.signedBytes(), post.signature, post.publicKey)) {
      debugPrint('Board: Post ${post.id} mit ungültiger Signatur verworfen');
      return false;
    }
    if (!_rate.allow(keyHex)) {
      debugPrint('Board: Rate-Limit für $keyHex');
      return false;
    }
    final hidden = _filter.flags(post.text);
    _posts[post.id] = BoardPost(post, hidden: hidden, mine: _myKeys.contains(keyHex));
    await _repo.upsert(post, hidden: hidden);
    notifyListeners();
    return true;
  }

  Future<void> _onReaction(PostReaction r) async {
    final bp = _posts[r.postId];
    if (bp == null) return;
    final keyHex = bytesToHex(r.publicKey);
    if (_blocks.isPostKeyBlocked(keyHex)) return;
    if (!await DeviceIdentity.verify(r.signedBytes(), r.signature, r.publicKey)) return;
    if (!['👍', '❤️', '🙋'].contains(r.reaction)) return;
    bp.reactions[r.reaction] = (bp.reactions[r.reaction] ?? 0) + 1;
    await _repo.putReaction(r.postId, keyHex, r.reaction);
    notifyListeners();
  }

  /// Der Peer sagt, welche IDs er hat; wir schicken ihm den Rest.
  Future<void> _onSyncRequest(PeerId from, Map<String, Object?> m) async {
    final have = m.list('have').whereType<String>().toSet();
    final now = _clock();
    final missing = _posts.values
        .where((p) => !p.hidden && !p.post.isExpired(now) && !have.contains(p.post.id))
        .toList()
      ..sort((a, b) => b.post.timestamp.compareTo(a.post.timestamp));
    for (final p in missing.take(50)) {
      try {
        await _transport.send(from, Frame(FrameType.post, p.post.encode()).encode());
      } catch (e) {
        debugPrint('Board: Sync an $from abgebrochen: $e');
        return;
      }
    }
  }

  /// Bytes für die Board-Characteristic: `{ids: [...], ts}`.
  Uint8List indexBytes() {
    final now = _clock();
    final ids = _posts.values
        .where((p) => !p.hidden && !p.post.isExpired(now))
        .map((p) => p.post.id)
        .take(100)
        .toList();
    return CborCodec.encode({'ids': ids, 'ts': now.millisecondsSinceEpoch});
  }

  /// Neuer Peer im Radar → Board abgleichen (beide Richtungen).
  Future<void> _onPeerResolved(RadarPeer peer) => syncWith(peer.peerId);

  Future<void> syncWith(PeerId peerId) async {
    try {
      final idx = CborCodec.decode(await _transport.read(peerId, ReadTarget.board));
      final theirs = idx.list('ids').whereType<String>().toSet();
      final mine = _posts.keys.toSet();
      // Ihm fehlt: alles, was wir haben und er nicht → er fragt nicht, wir schicken direkt.
      final now = _clock();
      final toSend = _posts.values
          .where((p) => !p.hidden && !p.post.isExpired(now) && !theirs.contains(p.post.id))
          .take(50);
      for (final p in toSend) {
        await _transport.send(peerId, Frame(FrameType.post, p.post.encode()).encode());
      }
      // Uns fehlt: seine IDs, die wir nicht kennen → Sync-Anfrage.
      if (theirs.difference(mine).isNotEmpty) {
        await _transport.send(
          peerId,
          Frame(FrameType.postSyncReq, CborCodec.encode({'have': mine.toList()})).encode(),
        );
      }
    } catch (e) {
      debugPrint('Board: Sync mit $peerId fehlgeschlagen: $e');
    }
  }

  // ------------------------------------------------------------- Moderation

  Future<void> hide(String postId) async {
    final bp = _posts[postId];
    if (bp == null) return;
    bp.hidden = true;
    await _repo.upsert(bp.post, hidden: true);
    notifyListeners();
  }

  Future<void> blockAuthor(String postId) async {
    final bp = _posts[postId];
    if (bp == null) return;
    await _blocks.blockPostKey(bp.authorKeyHex, label: bp.post.alias);
    if (bp.post.isProfilePost) {
      await _blocks.blockFingerprint(DeviceIdentity.fingerprintOf(bp.post.publicKey), label: bp.post.alias);
    }
    for (final p in _posts.values.where((p) => p.authorKeyHex == bp.authorKeyHex)) {
      p.hidden = true;
      await _repo.upsert(p.post, hidden: true);
    }
    notifyListeners();
  }

  Future<void> report(String postId, String reason) async {
    final bp = _posts[postId];
    if (bp == null) return;
    await _blocks.report(
      targetKind: 'post',
      target: bp.authorKeyHex,
      reason: reason,
      snapshot: '${bp.post.alias}: ${bp.post.text}',
    );
    await blockAuthor(postId);
  }

  Future<void> deleteOwn(String postId) async {
    final bp = _posts[postId];
    if (bp == null || !bp.mine) return;
    _posts.remove(postId);
    await _repo.delete(postId);
    notifyListeners();
  }

  Future<void> _cleanup() async {
    final now = _clock();
    final before = _posts.length;
    _posts.removeWhere((_, p) => p.post.isExpired(now));
    await _repo.deleteExpired(now);
    _rate.prune();
    if (_posts.length != before) notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
