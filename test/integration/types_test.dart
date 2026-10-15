@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('types', () {
    late Surreal db;

    setUp(() async => db = await connectRoot(wsUrl));
    tearDown(() async => db.close());

    test('datetimes before 1970 round trip', () async {
      final [decoded, matches] = await db.query(
        r'RETURN d"1969-12-31T23:59:59.5Z"; '
        r'RETURN $when == d"1969-12-31T23:59:59.5Z";',
        bindings: {'when': DateTime.utc(1969, 12, 31, 23, 59, 59, 500)},
      );
      expect(decoded, const SurrealDateTime(-1, 500000000));
      expect(matches, isTrue);
    });

    test('range bounds decode with their inclusivity', () async {
      final [half, closed, open] =
          await db.query('RETURN 1..5; RETURN 1..=5; RETURN 1>..5;');
      expect(half, const Range(begin: BoundIncluded(1), end: BoundExcluded(5)));
      expect(
          closed, const Range(begin: BoundIncluded(1), end: BoundIncluded(5)));
      expect(open, const Range(begin: BoundExcluded(1), end: BoundExcluded(5)));
    });

    test('an exclusive range bound round trips through the server', () async {
      const range = Range(begin: BoundIncluded(1), end: BoundExcluded(5));
      final [echoed, matches] = await db.query(
          r'RETURN $range; RETURN $range == 1..5;',
          bindings: {'range': range});
      expect(echoed, range);
      expect(matches, isTrue);
    });
  }, skip: skipIntegration);
}
