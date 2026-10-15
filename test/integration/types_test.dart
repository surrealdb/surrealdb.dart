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
  }, skip: skipIntegration);
}
