import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

import '../protocol/models.dart';

/// Lokale Datenbank (sembast). Auf dem Gerät als Datei im App-Verzeichnis,
/// in Tests und im Demo-Modus im Arbeitsspeicher.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static Future<AppDatabase> openFile(String path) async =>
      AppDatabase._(await databaseFactoryIo.openDatabase(path));

  static Future<AppDatabase> openMemory() async =>
      AppDatabase._(await newDatabaseFactoryMemory().openDatabase('umkreis'));

  late final SettingsRepository settings = SettingsRepository(_db);
  late final PostRepository posts = PostRepository(_db);
  late final ChatRepository chats = ChatRepository(_db);
  late final BlockRepository blocks = BlockRepository(_db);

  Future<void> close() => _db.close();

  /// Löscht alle Daten (App zurücksetzen).
  Future<void> wipe() async {
    await _db.transaction((txn) async {
      for (final store in [
        SettingsRepository._store,
        PostRepository._posts,
        PostRepository._reactions,
        ChatRepository._chats,
        ChatRepository._messages,
        BlockRepository._store,
        BlockRepository._reports,
      ]) {
        await store.delete(txn);
      }
    });
  }
}

String _b64(Uint8List b) => base64Encode(b);
Uint8List _unb64(Object? s) => s is String ? base64Decode(s) : Uint8List(0);

// ------------------------------------------------------------------ Settings

class SettingsRepository {
  SettingsRepository(this._db);
  final Database _db;
  static final _store = StoreRef<String, Object?>('settings');

  Future<T?> get<T>(String key) async => await _store.record(key).get(_db) as T?;
  Future<void> set(String key, Object? value) => _store.record(key).put(_db, value);
  Future<void> remove(String key) => _store.record(key).delete(_db);

  Future<Uint8List?> getBytes(String key) async {
    final v = await get<String>(key);
    return v == null ? null : base64Decode(v);
  }

  Future<void> setBytes(String key, Uint8List value) => set(key, base64Encode(value));
}

// --------------------------------------------------------------------- Posts

class PostRepository {
  PostRepository(this._db);
  final Database _db;
  static final _posts = stringMapStoreFactory.store('posts');
  static final _reactions = stringMapStoreFactory.store('reactions');

  Future<void> upsert(Post post, {bool hidden = false}) =>
      _posts.record(post.id).put(_db, _postToDb(post, hidden));

  Future<bool> exists(String id) => _posts.record(id).exists(_db);

  Future<List<(Post, bool hidden)>> all() async {
    final records = await _posts.find(_db);
    return records.map((r) => _postFromDb(r.value)).toList();
  }

  Future<void> deleteExpired(DateTime now) async {
    final records = await _posts.find(_db);
    final expired = records.where((r) => _postFromDb(r.value).$1.isExpired(now)).map((r) => r.key);
    await _posts.records(expired).delete(_db);
  }

  Future<void> delete(String id) => _posts.record(id).delete(_db);

  Future<void> putReaction(String postId, String pubkeyHex, String reaction) =>
      _reactions.record('$postId:$pubkeyHex').put(_db, {
        'postId': postId,
        'pubkey': pubkeyHex,
        'reaction': reaction,
      });

  /// reactions[postId][reaction] = count
  Future<Map<String, Map<String, int>>> reactionCounts() async {
    final out = <String, Map<String, int>>{};
    for (final r in await _reactions.find(_db)) {
      final postId = r.value['postId'] as String;
      final reaction = r.value['reaction'] as String;
      final m = out.putIfAbsent(postId, () => {});
      m[reaction] = (m[reaction] ?? 0) + 1;
    }
    return out;
  }

  static Map<String, Object?> _postToDb(Post p, bool hidden) => {
        'id': p.id,
        'ts': p.timestamp.millisecondsSinceEpoch,
        'ttl': p.ttl.inSeconds,
        'alias': p.alias,
        'emoji': p.emoji,
        'tag': p.tag,
        'text': p.text,
        'replyTo': p.replyTo,
        'sig': _b64(p.signature),
        'pubkey': _b64(p.publicKey),
        'hops': p.hops,
        'profile': p.isProfilePost,
        'hidden': hidden,
      };

  static (Post, bool) _postFromDb(Map<String, Object?> m) => (
        Post(
          id: m['id'] as String,
          timestamp: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
          ttl: Duration(seconds: m['ttl'] as int),
          alias: m['alias'] as String? ?? '',
          emoji: m['emoji'] as String? ?? '',
          tag: m['tag'] as String? ?? '',
          text: m['text'] as String? ?? '',
          replyTo: m['replyTo'] as String?,
          signature: _unb64(m['sig']),
          publicKey: _unb64(m['pubkey']),
          hops: m['hops'] as int? ?? 0,
          isProfilePost: m['profile'] as bool? ?? false,
        ),
        m['hidden'] as bool? ?? false,
      );
}

// --------------------------------------------------------------------- Chats

enum ChatState { incomingRequest, outgoingPending, active, rejected, blocked }

class StoredChat {
  StoredChat({
    required this.fingerprint,
    required this.alias,
    required this.emoji,
    required this.state,
    this.session,
    this.peerAliasSecret,
    this.revealedProfile,
    required this.createdAt,
    required this.updatedAt,
    this.unread = 0,
  });

  final String fingerprint;
  String alias;
  String emoji;
  ChatState state;
  Uint8List? session;
  Uint8List? peerAliasSecret;
  Profile? revealedProfile;
  final DateTime createdAt;
  DateTime updatedAt;
  int unread;

  Map<String, Object?> toDb() => {
        'fingerprint': fingerprint,
        'alias': alias,
        'emoji': emoji,
        'state': state.name,
        'session': session == null ? null : _b64(session!),
        'peerAliasSecret': peerAliasSecret == null ? null : _b64(peerAliasSecret!),
        'revealedProfile': revealedProfile?.toMap(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'unread': unread,
      };

  static StoredChat fromDb(Map<String, Object?> m) => StoredChat(
        fingerprint: m['fingerprint'] as String,
        alias: m['alias'] as String? ?? '',
        emoji: m['emoji'] as String? ?? '',
        state: ChatState.values.firstWhere((s) => s.name == m['state'], orElse: () => ChatState.active),
        session: m['session'] == null ? null : _unb64(m['session']),
        peerAliasSecret: m['peerAliasSecret'] == null ? null : _unb64(m['peerAliasSecret']),
        revealedProfile: m['revealedProfile'] is Map
            ? Profile.fromMap((m['revealedProfile'] as Map).map((k, v) => MapEntry(k.toString(), v)))
            : null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updatedAt'] as int),
        unread: m['unread'] as int? ?? 0,
      );
}

enum MessageStatus { pending, sent, delivered, received }

class StoredMessage {
  StoredMessage({
    required this.id,
    required this.chatFingerprint,
    required this.timestamp,
    required this.kind,
    required this.body,
    required this.outgoing,
    required this.status,
  });

  final String id;
  final String chatFingerprint;
  final DateTime timestamp;
  final MessageKind kind;
  final String body;
  final bool outgoing;
  MessageStatus status;

  Map<String, Object?> toDb() => {
        'id': id,
        'chat': chatFingerprint,
        'ts': timestamp.millisecondsSinceEpoch,
        'kind': kind.name,
        'body': body,
        'outgoing': outgoing,
        'status': status.name,
      };

  static StoredMessage fromDb(Map<String, Object?> m) => StoredMessage(
        id: m['id'] as String,
        chatFingerprint: m['chat'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
        kind: MessageKind.fromWire(m['kind'] as String? ?? 'text'),
        body: m['body'] as String? ?? '',
        outgoing: m['outgoing'] as bool? ?? false,
        status: MessageStatus.values.firstWhere((s) => s.name == m['status'], orElse: () => MessageStatus.sent),
      );
}

class ChatRepository {
  ChatRepository(this._db);
  final Database _db;
  static final _chats = stringMapStoreFactory.store('chats');
  static final _messages = stringMapStoreFactory.store('messages');

  Future<void> upsertChat(StoredChat chat) => _chats.record(chat.fingerprint).put(_db, chat.toDb());
  Future<void> deleteChat(String fingerprint) async {
    await _chats.record(fingerprint).delete(_db);
    await _messages.delete(_db, finder: Finder(filter: Filter.equals('chat', fingerprint)));
  }

  Future<List<StoredChat>> allChats() async =>
      (await _chats.find(_db)).map((r) => StoredChat.fromDb(r.value)).toList();

  Future<void> upsertMessage(StoredMessage m) => _messages.record(m.id).put(_db, m.toDb());

  Future<List<StoredMessage>> messagesFor(String fingerprint) async {
    final records = await _messages.find(
      _db,
      finder: Finder(filter: Filter.equals('chat', fingerprint), sortOrders: [SortOrder('ts')]),
    );
    return records.map((r) => StoredMessage.fromDb(r.value)).toList();
  }

  Future<List<StoredMessage>> allMessages() async =>
      (await _messages.find(_db, finder: Finder(sortOrders: [SortOrder('ts')])))
          .map((r) => StoredMessage.fromDb(r.value))
          .toList();
}

// -------------------------------------------------------------------- Blocks

enum BlockKind { fingerprint, postKey }

class BlockEntry {
  BlockEntry({required this.kind, required this.value, required this.at, this.label = ''});
  final BlockKind kind;
  final String value;
  final DateTime at;
  final String label;

  Map<String, Object?> toDb() => {
        'kind': kind.name,
        'value': value,
        'at': at.millisecondsSinceEpoch,
        'label': label,
      };

  static BlockEntry fromDb(Map<String, Object?> m) => BlockEntry(
        kind: BlockKind.values.firstWhere((k) => k.name == m['kind'], orElse: () => BlockKind.fingerprint),
        value: m['value'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(m['at'] as int),
        label: m['label'] as String? ?? '',
      );
}

class Report {
  Report({required this.id, required this.targetKind, required this.target, required this.reason, required this.at, this.snapshot = ''});
  final String id;
  final String targetKind;
  final String target;
  final String reason;
  final DateTime at;
  final String snapshot;

  Map<String, Object?> toDb() => {
        'id': id,
        'targetKind': targetKind,
        'target': target,
        'reason': reason,
        'at': at.millisecondsSinceEpoch,
        'snapshot': snapshot,
      };

  static Report fromDb(Map<String, Object?> m) => Report(
        id: m['id'] as String,
        targetKind: m['targetKind'] as String,
        target: m['target'] as String,
        reason: m['reason'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch(m['at'] as int),
        snapshot: m['snapshot'] as String? ?? '',
      );
}

class BlockRepository {
  BlockRepository(this._db);
  final Database _db;
  static final _store = stringMapStoreFactory.store('blocks');
  static final _reports = stringMapStoreFactory.store('reports');

  Future<void> put(BlockEntry e) => _store.record('${e.kind.name}:${e.value}').put(_db, e.toDb());
  Future<void> remove(BlockKind kind, String value) => _store.record('${kind.name}:$value').delete(_db);
  Future<List<BlockEntry>> all() async =>
      (await _store.find(_db)).map((r) => BlockEntry.fromDb(r.value)).toList();

  Future<void> putReport(Report r) => _reports.record(r.id).put(_db, r.toDb());
  Future<List<Report>> reports() async =>
      (await _reports.find(_db)).map((r) => Report.fromDb(r.value)).toList();
}
