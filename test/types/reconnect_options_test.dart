import 'dart:math';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  group('ReconnectOptions defaults', () {
    test('match the JavaScript SDK', () {
      const options = ReconnectOptions();
      expect(options.attempts, 5);
      expect(options.retryDelay, const Duration(seconds: 1));
      expect(options.retryDelayMax, const Duration(seconds: 60));
      expect(options.retryDelayMultiplier, 2.0);
      expect(options.retryDelayJitter, 0.1);
    });

    test('the delay for attempt n is retryDelay * multiplier^n, capped', () {
      const options = ReconnectOptions(retryDelayJitter: 0);
      expect(options.delayForAttempt(1), const Duration(seconds: 2));
      expect(options.delayForAttempt(2), const Duration(seconds: 4));
      expect(options.delayForAttempt(5), const Duration(seconds: 32));
      expect(options.delayForAttempt(6), const Duration(seconds: 60));
    });

    test('jitter varies the delay by at most the jitter fraction', () {
      const options = ReconnectOptions();
      final random = Random(1);
      for (var i = 0; i < 100; i++) {
        final ms = options.delayForAttempt(1, random: random).inMilliseconds;
        expect(ms, inInclusiveRange(1800, 2200));
      }
    });
  });
}
