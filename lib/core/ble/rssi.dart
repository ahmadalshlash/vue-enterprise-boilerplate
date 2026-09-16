/// Nähe-Stufen laut konzept/technik.md Abschnitt 3.
enum Proximity {
  veryNear,
  near,
  inRange;

  /// Schwellen (gemittelter RSSI in dBm), pro Plattform kalibrierbar.
  static int veryNearThreshold = -65;
  static int nearThreshold = -80;

  static Proximity fromRssi(int rssi) {
    if (rssi > veryNearThreshold) return Proximity.veryNear;
    if (rssi > nearThreshold) return Proximity.near;
    return Proximity.inRange;
  }

  /// Sortierreihenfolge: nah zuerst.
  int get rank => index;
}

/// Glättet RSSI-Werte über ein gleitendes Fenster (Median).
class RssiSmoother {
  RssiSmoother({this.window = 5});

  final int window;
  final List<int> _samples = [];

  void add(int rssi) {
    _samples.add(rssi);
    if (_samples.length > window) _samples.removeAt(0);
  }

  bool get isEmpty => _samples.isEmpty;

  int get value {
    if (_samples.isEmpty) return -100;
    final sorted = List<int>.from(_samples)..sort();
    return sorted[sorted.length ~/ 2];
  }

  Proximity get proximity => Proximity.fromRssi(value);
}

/// Grobe Distanzschätzung (nur für Debug-Anzeigen, nie für Nutzer):
/// `d = 10 ^ ((txPower - rssi) / (10 * n))`.
double estimateDistanceMeters(int rssi, {int txPower = -59, double pathLoss = 2.7}) {
  if (rssi == 0) return -1;
  return _pow10((txPower - rssi) / (10 * pathLoss));
}

double _pow10(double x) {
  var result = 1.0;
  final intPart = x.floor();
  for (var i = 0; i < intPart.abs(); i++) {
    result = intPart >= 0 ? result * 10 : result / 10;
  }
  final frac = x - intPart;
  // 10^frac via e^(frac*ln10)
  const ln10 = 2.302585092994046;
  var term = 1.0;
  var sum = 1.0;
  final y = frac * ln10;
  for (var k = 1; k < 12; k++) {
    term *= y / k;
    sum += term;
  }
  return result * sum;
}
