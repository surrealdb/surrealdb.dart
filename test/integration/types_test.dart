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

    test('NONE and NULL stay distinct', () async {
      final [noneValue, nullValue, object, noneMatches, nullMatches, fields] =
          await db.query(
              r'RETURN NONE; RETURN NULL; RETURN {a: NONE, b: NULL}; '
              r'RETURN $n IS NONE; RETURN $u IS NULL; '
              r'RETURN [type::is_none($o.a), type::is_null($o.b)];',
              bindings: {
            'n': none,
            'u': null,
            'o': {'a': none, 'b': null},
          });
      expect(noneValue, same(none));
      expect(nullValue, isNull);
      expect(object, {'a': none, 'b': null});
      expect(noneMatches, isTrue);
      expect(nullMatches, isTrue);
      expect(fields, [true, true]);
    });

    test('a method that returns nothing gives null', () async {
      await db.query('DEFINE TABLE IF NOT EXISTS nothing_here');
      expect(await db.select(const RecordId('nothing_here', 1)), isNull);
    });

    test('a function that returns NONE gives none, not null', () async {
      await db.query('DEFINE FUNCTION OVERWRITE fn::nothing(\$null: bool) { '
          'RETURN IF \$null { NULL } ELSE { NONE } }');
      expect(await db.run('fn::nothing', args: [false]), same(none));
      expect(await db.run('fn::nothing', args: [true]), isNull);
    });

    test('sets round trip as a Set', () async {
      final [set, isSet] = await db
          .query(r'RETURN <set>[3, 1, 1]; RETURN type::is_set($s);', bindings: {
        's': {1, 2}
      });
      expect(set, isA<Set<Object?>>());
      expect(set, {1, 3});
      expect(isSet, isTrue);
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
