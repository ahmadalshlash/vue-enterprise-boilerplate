/// Lokaler Wortfilter: Treffer werden ausgeblendet, nicht gelöscht.
/// Die Liste ist bewusst kurz und erweiterbar (Einstellungen, spätere
/// Community-Listen). Sie soll offensichtliche Beleidigungen abfangen,
/// nicht Zensur betreiben.
class WordFilter {
  WordFilter({List<String>? words}) : _words = (words ?? defaultWords).map(_normalize).toSet();

  static const defaultWords = <String>[
    'hurensohn',
    'wichser',
    'fotze',
    'schlampe',
    'missgeburt',
    'nazi',
    'heil hitler',
    'nigger',
    'kanake',
    'schwuchtel',
    'faggot',
    'retard',
    'cunt',
  ];

  final Set<String> _words;

  bool get isEmpty => _words.isEmpty;

  /// `true`, wenn der Text ein gelistetes Wort enthält.
  bool flags(String text) {
    final norm = _normalize(text);
    for (final w in _words) {
      if (norm.contains(w)) return true;
    }
    return false;
  }

  void add(String word) => _words.add(_normalize(word));
  void remove(String word) => _words.remove(_normalize(word));

  static String _normalize(String s) => s
      .toLowerCase()
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
}
