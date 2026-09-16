import 'dart:async';
import 'dart:math';

import '../core/ble/fake_transport.dart';
import '../core/crypto/key_store.dart';
import '../core/protocol/models.dart';
import '../core/services/engine.dart';
import '../core/storage/app_database.dart';

/// Simulierte Umgebung: mehrere vollständige Engines („Bots“) mit
/// Autopilot, die Anfragen annehmen, antworten und posten. Sie laufen über
/// exakt denselben Code wie echte Geräte, nur der Transport ist simuliert.
class DemoWorld {
  DemoWorld({Random? random}) : _random = random ?? Random(7);

  final Random _random;
  final FakeWorld world = FakeWorld(tick: const Duration(milliseconds: 1500), fakeMtu: 180);
  final List<_Bot> _bots = [];
  Timer? _wander;
  Timer? _chatter;

  FakeTransport createUserTransport() => world.createNode('me');

  static const _botSpecs = [
    _BotSpec('bot1', 4, 1, VisibilityMode.anonymous, status: 'Suche Mitfahrgelegenheit nach Köln'),
    _BotSpec('bot2', 12, -6, VisibilityMode.profile,
        profile: Profile(name: 'Lena', emoji: '🎸', bio: 'Musik, Kaffee, Zugfahren', tags: ['musik', 'kaffee'])),
    _BotSpec('bot3', 25, 10, VisibilityMode.anonymous, status: 'Wer hat ein Ladekabel?'),
    _BotSpec('bot4', 45, -20, VisibilityMode.profile,
        profile: Profile(name: 'Jonas', emoji: '🚴', bio: 'Radfahrer, Wagen 3', tags: ['rad', 'sport'])),
    _BotSpec('bot5', 70, 30, VisibilityMode.anonymous),
    _BotSpec('bot6', 15, 15, VisibilityMode.anonymous, status: 'Pause am Bahnsteig 4'),
  ];

  static const _posts = [
    ('mitfahren', 'Fahre um 18:10 weiter nach Köln, zwei Plätze frei. Meldet euch!'),
    ('verloren', 'Hat jemand einen schwarzen Rucksack mit rotem Anhänger gesehen? Wagen 5.'),
    ('frage', 'Weiß jemand, ob der Anschlusszug nach Bonn wartet?'),
    ('party', 'Nachher Session am Bahnsteig 2, wer hat eine Gitarre?'),
    ('hilfe', 'Brauche kurz Hilfe mit einem Kinderwagen an der Treppe, Ausgang Süd.'),
  ];

  static const _replies = [
    'Hey! Ja, bin auch hier. Wo genau bist du?',
    'Klar, gerne! Schreib mir einfach, wenn du da bist.',
    'Haha, gute Frage. Ich glaube Wagen 7?',
    'Danke für die Nachricht! Bin gleich am Ausgang.',
    'Ja, passt. Bis gleich!',
  ];

  Future<void> start() async {
    for (final spec in _botSpecs) {
      final transport = world.createNode(spec.id, x: spec.x, y: spec.y);
      final engine = await Engine.create(
        transport: transport,
        db: await AppDatabase.openMemory(),
        keyStore: InMemoryKeyStore(),
      );
      if (spec.profile != null) {
        await engine.identity.setProfile(spec.profile);
      }
      await engine.identity.setMode(spec.mode);
      if (spec.status != null) await engine.identity.setStatus(spec.status!);
      await engine.identity.completeOnboarding();
      await engine.start();
      final bot = _Bot(spec, engine, _random);
      bot.attach();
      _bots.add(bot);
    }
    // Ein paar Posts vorab.
    for (var i = 0; i < _posts.length; i++) {
      final (tag, text) = _posts[i];
      final bot = _bots[i % _bots.length];
      await bot.engine.board.createPost(text: text, tag: tag, asProfile: bot.spec.mode == VisibilityMode.profile);
    }
    world.start();
    _wander = Timer.periodic(const Duration(seconds: 6), (_) => _wanderStep());
    _chatter = Timer.periodic(const Duration(seconds: 45), (_) => _randomPost());
  }

  void _wanderStep() {
    for (final bot in _bots) {
      final dx = (_random.nextDouble() - 0.5) * 12;
      final dy = (_random.nextDouble() - 0.5) * 12;
      final t = bot.engine.transport as FakeTransport;
      world.moveTo(bot.spec.id, (t.x + dx).clamp(1, 95), (t.y + dy).clamp(-40, 40));
    }
  }

  Future<void> _randomPost() async {
    final bot = _bots[_random.nextInt(_bots.length)];
    final (tag, text) = _posts[_random.nextInt(_posts.length)];
    try {
      await bot.engine.board.createPost(text: text, tag: tag);
    } catch (_) {}
  }

  Future<void> stop() async {
    _wander?.cancel();
    _chatter?.cancel();
    world.stop();
    for (final b in _bots) {
      await b.engine.stop();
    }
  }
}

class _BotSpec {
  const _BotSpec(this.id, this.x, this.y, this.mode, {this.status, this.profile});
  final String id;
  final double x;
  final double y;
  final VisibilityMode mode;
  final String? status;
  final Profile? profile;
}

class _Bot {
  _Bot(this.spec, this.engine, this._random);
  final _BotSpec spec;
  final Engine engine;
  final Random _random;
  final Set<String> _answered = {};

  void attach() {
    engine.chats.incomingRequests.listen((chat) async {
      await Future<void>.delayed(Duration(seconds: 2 + _random.nextInt(3)));
      await engine.chats.accept(chat.fingerprint);
      await Future<void>.delayed(const Duration(seconds: 2));
      await _replyTo(chat.fingerprint);
    });
    engine.chats.addListener(_onChatsChanged);
  }

  void _onChatsChanged() {
    for (final chat in engine.chats.active) {
      final last = chat.lastMessage;
      if (last == null || last.outgoing || _answered.contains(last.id)) continue;
      _answered.add(last.id);
      Future<void>.delayed(Duration(seconds: 2 + _random.nextInt(4)), () => _replyTo(chat.fingerprint));
    }
  }

  Future<void> _replyTo(String fingerprint) async {
    try {
      final text = DemoWorld._replies[_random.nextInt(DemoWorld._replies.length)];
      await engine.chats.sendMessage(fingerprint, text);
      if (spec.mode == VisibilityMode.profile && _random.nextBool()) {
        await engine.chats.reveal(fingerprint);
      }
    } catch (_) {}
  }
}
