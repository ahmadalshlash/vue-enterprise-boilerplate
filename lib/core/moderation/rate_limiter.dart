/// Gleitendes Zeitfenster pro Schlüssel: erlaubt höchstens [limit]
/// Ereignisse innerhalb von [window].
class RateLimiter {
  RateLimiter({required this.limit, required this.window, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final int limit;
  final Duration window;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _events = {};

  /// Registriert ein Ereignis. Gibt `false` zurück, wenn das Limit
  /// überschritten ist (das Ereignis wird dann nicht gezählt).
  bool allow(String key) {
    final now = _clock();
    final list = _events.putIfAbsent(key, () => []);
    list.removeWhere((t) => now.difference(t) > window);
    if (list.length >= limit) return false;
    list.add(now);
    return true;
  }

  void reset(String key) => _events.remove(key);

  /// Entfernt Schlüssel ohne Ereignisse im Fenster (Speicher freigeben).
  void prune() {
    final now = _clock();
    _events.removeWhere((_, l) {
      l.removeWhere((t) => now.difference(t) > window);
      return l.isEmpty;
    });
  }
}
