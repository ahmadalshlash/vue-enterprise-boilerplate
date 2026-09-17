import 'package:flutter/foundation.dart';

import 'cbor_codec.dart';
import 'constants.dart';

/// Sichtbarkeits-Modus laut konzept/README.md Abschnitt 3.2.
enum VisibilityMode {
  invisible,
  anonymous,
  profile;

  static VisibilityMode fromWire(int v) => switch (v) {
        0 => VisibilityMode.invisible,
        2 => VisibilityMode.profile,
        _ => VisibilityMode.anonymous,
      };

  int get wire => index;
}

/// Was ein Gerät über die Presence-Characteristic preisgibt.
@immutable
class Presence {
  const Presence({
    this.version = ProtocolConstants.version,
    required this.mode,
    required this.alias,
    required this.emoji,
    this.status = '',
    this.hasProfile = false,
    required this.eid,
  });

  final int version;
  final VisibilityMode mode;
  final String alias;
  final String emoji;
  final String status;
  final bool hasProfile;
  final Uint8List eid;

  Uint8List encode() => CborCodec.encode({
        'v': version,
        'mode': mode.wire,
        'alias': alias,
        'emoji': emoji,
        'status': status,
        'hasProfile': hasProfile,
        'eid': eid,
      });

  static Presence decode(Uint8List bytes) {
    final m = CborCodec.decode(bytes);
    return Presence(
      version: m.integer('v', fallback: 1),
      mode: VisibilityMode.fromWire(m.integer('mode', fallback: 1)),
      alias: m.str('alias'),
      emoji: m.str('emoji'),
      status: m.str('status'),
      hasProfile: m.boolean('hasProfile'),
      eid: m.bytes('eid') ?? Uint8List(0),
    );
  }

  String get displayName => alias.isEmpty ? '?' : alias;
}

/// Frei gewähltes Profil (Modus „Profil“). Wird signiert übertragen.
@immutable
class Profile {
  const Profile({
    required this.name,
    this.bio = '',
    this.tags = const [],
    this.emoji = '🙂',
  });

  final String name;
  final String bio;
  final List<String> tags;
  final String emoji;

  Map<String, Object?> toMap() => {
        'name': name,
        'bio': bio,
        'tags': tags,
        'emoji': emoji,
      };

  static Profile fromMap(Map<String, Object?> m) => Profile(
        name: m.str('name'),
        bio: m.str('bio'),
        tags: m.list('tags').whereType<String>().toList(),
        emoji: m.str('emoji', fallback: '🙂'),
      );

  Profile copyWith({String? name, String? bio, List<String>? tags, String? emoji}) =>
      Profile(
        name: name ?? this.name,
        bio: bio ?? this.bio,
        tags: tags ?? this.tags,
        emoji: emoji ?? this.emoji,
      );
}

/// Ein Board-Post. Öffentlich, signiert, nicht verschlüsselt.
@immutable
class Post {
  const Post({
    required this.id,
    required this.timestamp,
    required this.ttl,
    required this.alias,
    required this.emoji,
    required this.tag,
    required this.text,
    this.replyTo,
    required this.signature,
    required this.publicKey,
    this.hops = 0,
    this.isProfilePost = false,
  });

  /// 16 zufällige Byte, hex-kodiert.
  final String id;
  final DateTime timestamp;
  final Duration ttl;
  final String alias;
  final String emoji;
  final String tag;
  final String text;
  final String? replyTo;
  final Uint8List signature;
  final Uint8List publicKey;
  final int hops;
  final bool isProfilePost;

  DateTime get expiresAt => timestamp.add(ttl);
  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  /// Bytes, über die signiert wird (ohne Signatur und Hops).
  Uint8List signedBytes() => CborCodec.encode({
        'label': ProtocolConstants.postSignLabel,
        'id': id,
        'ts': timestamp.millisecondsSinceEpoch,
        'ttl': ttl.inSeconds,
        'alias': alias,
        'emoji': emoji,
        'tag': tag,
        'text': text,
        'replyTo': replyTo,
        'profile': isProfilePost,
      });

  Map<String, Object?> toMap() => {
        'id': id,
        'ts': timestamp.millisecondsSinceEpoch,
        'ttl': ttl.inSeconds,
        'alias': alias,
        'emoji': emoji,
        'tag': tag,
        'text': text,
        'replyTo': replyTo,
        'sig': signature,
        'pubkey': publicKey,
        'hops': hops,
        'profile': isProfilePost,
      };

  static Post fromMap(Map<String, Object?> m) => Post(
        id: m.str('id'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(m.integer('ts')),
        ttl: Duration(seconds: m.integer('ttl', fallback: 3600)),
        alias: m.str('alias'),
        emoji: m.str('emoji'),
        tag: m.str('tag'),
        text: m.str('text'),
        replyTo: m['replyTo'] is String ? m['replyTo'] as String : null,
        signature: m.bytes('sig') ?? Uint8List(0),
        publicKey: m.bytes('pubkey') ?? Uint8List(0),
        hops: m.integer('hops'),
        isProfilePost: m.boolean('profile'),
      );

  Uint8List encode() => CborCodec.encode(toMap());
  static Post decode(Uint8List b) => fromMap(CborCodec.decode(b));

  Post withHops(int h) => Post(
        id: id,
        timestamp: timestamp,
        ttl: ttl,
        alias: alias,
        emoji: emoji,
        tag: tag,
        text: text,
        replyTo: replyTo,
        signature: signature,
        publicKey: publicKey,
        hops: h,
        isProfilePost: isProfilePost,
      );
}

/// Reaktion auf einen Post.
@immutable
class PostReaction {
  const PostReaction({
    required this.postId,
    required this.reaction,
    required this.signature,
    required this.publicKey,
  });

  final String postId;
  final String reaction;
  final Uint8List signature;
  final Uint8List publicKey;

  Uint8List signedBytes() => CborCodec.encode({
        'label': '${ProtocolConstants.postSignLabel}/react',
        'postId': postId,
        'reaction': reaction,
      });

  Uint8List encode() => CborCodec.encode({
        'postId': postId,
        'reaction': reaction,
        'sig': signature,
        'pubkey': publicKey,
      });

  static PostReaction decode(Uint8List b) {
    final m = CborCodec.decode(b);
    return PostReaction(
      postId: m.str('postId'),
      reaction: m.str('reaction'),
      signature: m.bytes('sig') ?? Uint8List(0),
      publicKey: m.bytes('pubkey') ?? Uint8List(0),
    );
  }
}

/// Art einer Chat-Nachricht.
enum MessageKind {
  text,
  image,
  reveal,
  ack,

  /// Verschlüsselt übertragenes Alias-Secret, damit der Kontakt meine
  /// EIDs wiedererkennt (Store-and-Forward über Fenstergrenzen).
  contactKey;

  static MessageKind fromWire(String s) =>
      MessageKind.values.firstWhere((k) => k.name == s, orElse: () => MessageKind.text);
}

/// Klartext-Inhalt einer Chat-Nachricht (wird verschlüsselt übertragen).
@immutable
class ChatPayload {
  const ChatPayload({
    required this.id,
    required this.timestamp,
    this.kind = MessageKind.text,
    required this.body,
  });

  final String id;
  final DateTime timestamp;
  final MessageKind kind;
  final String body;

  Uint8List encode() => CborCodec.encode({
        'id': id,
        'ts': timestamp.millisecondsSinceEpoch,
        'kind': kind.name,
        'body': body,
      });

  static ChatPayload decode(Uint8List b) {
    final m = CborCodec.decode(b);
    return ChatPayload(
      id: m.str('id'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(m.integer('ts')),
      kind: MessageKind.fromWire(m.str('kind', fallback: 'text')),
      body: m.str('body'),
    );
  }
}
