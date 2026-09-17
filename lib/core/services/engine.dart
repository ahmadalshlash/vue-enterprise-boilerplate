import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/transport.dart';
import '../crypto/identity.dart';
import '../crypto/key_store.dart';
import '../moderation/block_service.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../storage/app_database.dart';
import 'board_service.dart';
import 'chat_service.dart';
import 'identity_service.dart';
import 'radar_service.dart';

/// Verbindet Transport, Identität, Radar, Chat und Board zu einer
/// laufenden Instanz der App-Logik. Eine Engine = ein Gerät.
class Engine extends ChangeNotifier {
  Engine._({
    required this.transport,
    required this.db,
    required this.identity,
    required this.radar,
    required this.chats,
    required this.board,
    required this.blocks,
    required DateTime Function() clock,
  }) : _clock = clock;

  final NearbyTransport transport;
  final AppDatabase db;
  final IdentityService identity;
  final RadarService radar;
  final ChatService chats;
  final BoardService board;
  final BlockService blocks;
  final DateTime Function() _clock;

  StreamSubscription? _inboundSub;
  StreamSubscription? _statusSub;
  Timer? _eidTimer;
  Timer? _aliasTimer;
  bool _running = false;
  TransportStatus _status = TransportStatus.unknown;

  bool get isRunning => _running;
  TransportStatus get transportStatus => _status;

  static Future<Engine> create({
    required NearbyTransport transport,
    required AppDatabase db,
    required KeyStore keyStore,
    DateTime Function()? clock,
  }) async {
    final now = clock ?? DateTime.now;
    final deviceIdentity = await DeviceIdentity.loadOrCreate(keyStore);
    final identity = IdentityService(db.settings, deviceIdentity, clock: now);
    await identity.load();
    final blocks = BlockService(db.blocks);
    await blocks.load();
    final radar = RadarService(transport, clock: now);
    final chats = ChatService(
      transport: transport,
      identity: identity,
      radar: radar,
      blocks: blocks,
      repo: db.chats,
      clock: now,
    );
    await chats.load();
    final board = BoardService(
      transport: transport,
      identity: identity,
      radar: radar,
      blocks: blocks,
      repo: db.posts,
      clock: now,
    );
    await board.load();
    final engine = Engine._(
      transport: transport,
      db: db,
      identity: identity,
      radar: radar,
      chats: chats,
      board: board,
      blocks: blocks,
      clock: now,
    );
    engine._wire();
    return engine;
  }

  void _wire() {
    transport.setProviders(TransportProviders(
      presence: identity.presenceBytes,
      profile: _profileBytes,
      board: board.indexBytes,
    ));
    identity.addListener(_onIdentityChanged);
  }

  Uint8List _cachedProfile = Uint8List(0);
  Uint8List _profileBytes() => _cachedProfile;

  Future<void> _refreshProfileBytes() async {
    _cachedProfile = await identity.signedProfileBytes();
  }

  VisibilityMode? _lastMode;
  Uint8List? _lastEid;

  Future<void> _onIdentityChanged() async {
    await _refreshProfileBytes();
    if (!_running) return;
    final eid = identity.currentEid();
    if (identity.mode != _lastMode || _lastEid == null || !listEquals(eid, _lastEid)) {
      await _applyAdvertising();
    }
  }

  Future<void> _applyAdvertising() async {
    _lastMode = identity.mode;
    _lastEid = identity.currentEid();
    try {
      await transport.setAdvertising(identity.isVisible ? _lastEid : null);
    } catch (e) {
      debugPrint('Engine: Advertising: $e');
    }
    notifyListeners();
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _refreshProfileBytes();
    _inboundSub = transport.inbound.listen(_onInbound);
    _statusSub = transport.statusChanges.listen((s) {
      _status = s;
      notifyListeners();
    });
    _status = transport.status;
    await transport.start();
    radar.start();
    chats.start();
    board.start();
    await _applyAdvertising();
    _scheduleEidRotation();
    _aliasTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkAlias());
    notifyListeners();
  }

  void _scheduleEidRotation() {
    _eidTimer?.cancel();
    final next = identity.nextEidRotation();
    var delay = next.difference(_clock().toUtc()) + const Duration(seconds: 1);
    if (delay.isNegative) delay = const Duration(seconds: 1);
    _eidTimer = Timer(delay, () async {
      if (!_running) return;
      await _applyAdvertising();
      _scheduleEidRotation();
    });
  }

  Future<void> _checkAlias() async {
    if (await identity.rotateAliasIfExpired()) {
      await chats.broadcastContactKey();
    }
  }

  /// Alias neu würfeln und Kontakte informieren.
  Future<void> rerollAlias() async {
    await identity.rerollAlias();
    await chats.broadcastContactKey();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _eidTimer?.cancel();
    _aliasTimer?.cancel();
    _inboundSub?.cancel();
    _statusSub?.cancel();
    _inboundSub = null;
    _statusSub = null;
    board.stop();
    chats.stop();
    await radar.stop();
    await transport.stop();
    notifyListeners();
  }

  Future<void> _onInbound(InboundFrame f) async {
    final Frame frame;
    try {
      frame = Frame.decode(f.bytes);
    } on UnsupportedFrameVersion catch (e) {
      debugPrint('Engine: Frame mit neuerer Version ${e.version} von ${f.peerId}');
      return;
    } on FrameFormatException catch (e) {
      debugPrint('Engine: Ungültiges Frame von ${f.peerId}: $e');
      return;
    }
    switch (frame.type) {
      case FrameType.hello:
      case FrameType.handshake:
      case FrameType.msg:
      case FrameType.ack:
      case FrameType.reveal:
        await chats.handleFrame(f.peerId, frame);
      case FrameType.post:
      case FrameType.postReact:
      case FrameType.postSyncReq:
        await board.handleFrame(f.peerId, frame);
      case FrameType.error:
        debugPrint('Engine: ERROR-Frame von ${f.peerId}');
    }
  }

  /// Alles löschen: Identität, Chats, Posts, Einstellungen.
  Future<void> resetAll(KeyStore keyStore) async {
    await stop();
    await db.wipe();
    await DeviceIdentity.reset(keyStore);
  }

  @override
  void dispose() {
    identity.removeListener(_onIdentityChanged);
    stop();
    super.dispose();
  }
}
