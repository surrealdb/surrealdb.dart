import 'package:surrealdb/memory.dart';
import 'package:test/test.dart';

void main() {
  group('normaliseScope', () {
    test('null returns null', () {
      expect(normaliseScope(null), isNull);
    });

    test('a single path becomes one clause', () {
      expect(normaliseScope('team/eng'), [
        ['team/eng'],
      ]);
    });

    test('a list of paths becomes a disjunction', () {
      expect(normaliseScope(['team/eng', 'org/acme']), [
        ['team/eng'],
        ['org/acme'],
      ]);
    });

    test('a nested list becomes a conjunction', () {
      expect(
          normaliseScope([
            ['team/eng', 'org/acme'],
          ]),
          [
            ['team/eng', 'org/acme'],
          ]);
    });

    test('drops empty strings and de duplicates within a clause', () {
      expect(
          normaliseScope([
            ['team/eng', '', 'team/eng', 'org/acme'],
          ]),
          [
            ['team/eng', 'org/acme'],
          ]);
    });

    test('drops empty clauses and returns null when nothing remains', () {
      expect(normaliseScope(['', <String>[]]), isNull);
    });
  });
}
