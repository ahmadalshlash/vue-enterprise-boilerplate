import 'package:flutter_test/flutter_test.dart';
import 'package:umkreis/core/ble/rssi.dart';
import 'package:umkreis/core/moderation/rate_limiter.dart';
import 'package:umkreis/core/moderation/word_filter.dart';

void main() {
  group('RateLimiter', () {
    test('allows up to limit within window, then blocks, then recovers', () {
      var now = DateTime(2026, 1, 1);
      final rl = RateLimiter(limit: 3, window: const Duration(minutes: 10), clock: () => now);
      expect(rl.allow('k'), true);
      expect(rl.allow('k'), true);
      expect(rl.allow('k'), true);
      expect(rl.allow('k'), false);
      expect(rl.allow('other'), true);
      now = now.add(const Duration(minutes: 11));
      expect(rl.allow('k'), true);
    });
  });

  group('WordFilter', () {
    test('flags listed words regardless of case and umlauts', () {
      final f = WordFilter();
      expect(f.flags('Du HURENSOHN!'), true);
      expect(f.flags('Schönes Wetter heute'), false);
      expect(f.flags('n.a.z.i'), true, reason: 'Satzzeichen werden entfernt');
      f.add('bananenbrot');
      expect(f.flags('Ich mag Bananenbrot'), true);
    });
  });

  group('Proximity', () {
    test('buckets by smoothed RSSI', () {
      final s = RssiSmoother();
      for (final v in [-50, -90, -55, -52, -51]) {
        s.add(v);
      }
      expect(s.value, -52);
      expect(s.proximity, Proximity.veryNear);
      expect(Proximity.fromRssi(-70), Proximity.near);
      expect(Proximity.fromRssi(-85), Proximity.inRange);
    });

    test('distance estimate is monotonic', () {
      expect(estimateDistanceMeters(-59), closeTo(1, 0.01));
      expect(estimateDistanceMeters(-80) > estimateDistanceMeters(-70), true);
    });
  });
}
