import 'package:surrealdb/memory.dart';
import 'package:test/test.dart';

void main() {
  group('idempotencyKey', () {
    final now = DateTime.utc(2026, 6, 16, 10, 0, 0);

    test('is a 64 character hex string', () {
      final key = idempotencyKey('POST', '/facts', '{}', now: now);
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('is stable for the same inputs within a bucket', () {
      final a = idempotencyKey('POST', '/facts', '{"text":"hi"}', now: now);
      final b = idempotencyKey('POST', '/facts', '{"text":"hi"}',
          now: now.add(const Duration(seconds: 10)));
      expect(a, b);
    });

    test('changes across buckets', () {
      final a = idempotencyKey('POST', '/facts', '{}', now: now);
      final b = idempotencyKey('POST', '/facts', '{}',
          now: now.add(const Duration(seconds: 31)));
      expect(a, isNot(b));
    });

    test('changes with the body', () {
      final a = idempotencyKey('POST', '/facts', '{"text":"a"}', now: now);
      final b = idempotencyKey('POST', '/facts', '{"text":"b"}', now: now);
      expect(a, isNot(b));
    });
  });
}
