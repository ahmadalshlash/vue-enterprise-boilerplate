import 'dart:typed_data';

/// Deterministischer Alias-Generator: aus dem Alias-Secret entstehen
/// Adjektiv, Tier und Emoji. Gleiches Secret → gleicher Alias.
class AliasGenerator {
  AliasGenerator._();

  static const adjectivesDe = [
    'Grüner', 'Blauer', 'Roter', 'Stiller', 'Flinker', 'Kluger', 'Wilder',
    'Sanfter', 'Mutiger', 'Heller', 'Dunkler', 'Schneller', 'Freundlicher',
    'Neugieriger', 'Fröhlicher', 'Ruhiger', 'Goldener', 'Silberner', 'Kleiner',
    'Großer', 'Tapferer', 'Lustiger', 'Wacher', 'Scheuer', 'Bunter', 'Kühler',
    'Warmer', 'Leiser', 'Lauter', 'Ferner', 'Naher', 'Junger',
  ];

  static const adjectivesEn = [
    'Green', 'Blue', 'Red', 'Quiet', 'Swift', 'Clever', 'Wild',
    'Gentle', 'Brave', 'Bright', 'Dark', 'Fast', 'Friendly',
    'Curious', 'Cheerful', 'Calm', 'Golden', 'Silver', 'Little',
    'Big', 'Bold', 'Funny', 'Awake', 'Shy', 'Colorful', 'Cool',
    'Warm', 'Soft', 'Loud', 'Distant', 'Near', 'Young',
  ];

  static const animals = [
    ('Fuchs', 'Fox', '🦊'),
    ('Falke', 'Falcon', '🦅'),
    ('Otter', 'Otter', '🦦'),
    ('Igel', 'Hedgehog', '🦔'),
    ('Wal', 'Whale', '🐳'),
    ('Panda', 'Panda', '🐼'),
    ('Wolf', 'Wolf', '🐺'),
    ('Frosch', 'Frog', '🐸'),
    ('Pinguin', 'Penguin', '🐧'),
    ('Eule', 'Owl', '🦉'),
    ('Hase', 'Hare', '🐰'),
    ('Dachs', 'Badger', '🦡'),
    ('Koala', 'Koala', '🐨'),
    ('Tiger', 'Tiger', '🐯'),
    ('Delfin', 'Dolphin', '🐬'),
    ('Biber', 'Beaver', '🦫'),
    ('Luchs', 'Lynx', '🐈'),
    ('Rabe', 'Raven', '🐦‍⬛'),
    ('Hirsch', 'Deer', '🦌'),
    ('Schwan', 'Swan', '🦢'),
    ('Kranich', 'Crane', '🪶'),
    ('Salamander', 'Salamander', '🦎'),
    ('Oktopus', 'Octopus', '🐙'),
    ('Elch', 'Moose', '🫎'),
    ('Marder', 'Marten', '🐾'),
    ('Bär', 'Bear', '🐻'),
    ('Kolibri', 'Hummingbird', '🐦'),
    ('Seepferd', 'Seahorse', '🐴'),
    ('Papagei', 'Parrot', '🦜'),
    ('Schildkröte', 'Turtle', '🐢'),
    ('Flamingo', 'Flamingo', '🦩'),
    ('Chamäleon', 'Chameleon', '🦎'),
  ];

  /// Erzeugt (alias, emoji) für ein Secret in der Sprache `de` oder `en`.
  static (String, String) generate(Uint8List secret, {String language = 'de'}) {
    final a = secret.isNotEmpty ? secret[0] : 0;
    final b = secret.length > 1 ? secret[1] : 0;
    final adjectives = language == 'en' ? adjectivesEn : adjectivesDe;
    final adjective = adjectives[a % adjectives.length];
    final animal = animals[b % animals.length];
    final noun = language == 'en' ? animal.$2 : animal.$1;
    return ('$adjective $noun', animal.$3);
  }
}
