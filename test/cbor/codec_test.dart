import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  const codec = CborCodec();

  Object? roundTrip(Object? value) => codec.decode(codec.encode(value));

  group('primitives', () {
    test('round trip', () {
      expect(roundTrip(42), 42);
      expect(roundTrip(-7), -7);
      expect(roundTrip('hello'), 'hello');
      expect(roundTrip(true), true);
      expect(roundTrip(false), false);
      expect(roundTrip(null), null);
      expect(roundTrip(3.5), 3.5);
    });

    test('lists and maps', () {
      expect(roundTrip([1, 2, 3]), [1, 2, 3]);
      expect(
        roundTrip({
          'name': 'Tobie',
          'tags': [1, 2]
        }),
        {
          'name': 'Tobie',
          'tags': [1, 2]
        },
      );
    });
  });

  group('value types', () {
    test('Table', () {
      expect(roundTrip(const Table('person')), const Table('person'));
    });

    test('RecordId with string id', () {
      const id = RecordId('person', 'tobie');
      expect(roundTrip(id), id);
    });

    test('RecordId with int id', () {
      const id = RecordId('temperature', 9000);
      expect(roundTrip(id), id);
    });

    test('RecordId with array id', () {
      const id = RecordId('point', [1, 2]);
      expect(roundTrip(id), id);
    });

    test('StringRecordId', () {
      const id = StringRecordId('person:tobie');
      expect(roundTrip(id), id);
    });

    test('Uuid', () {
      final uuid = Uuid('8c6c5b1e-3a3a-4b3a-9b3a-1a2b3c4d5e6f');
      expect(roundTrip(uuid), uuid);
    });

    test('Decimal', () {
      const decimal = Decimal('3.14159265358979');
      expect(roundTrip(decimal), decimal);
    });

    test('SurrealDuration', () {
      const duration = SurrealDuration(seconds: 90, nanoseconds: 500000000);
      expect(roundTrip(duration), duration);
    });

    test('SurrealDuration zero', () {
      const duration = SurrealDuration();
      expect(roundTrip(duration), duration);
    });

    test('SurrealDateTime', () {
      const dt = SurrealDateTime(1718532000, 123456789);
      expect(roundTrip(dt), dt);
    });

    test('SurrealFuture', () {
      const future = SurrealFuture('time::now()');
      expect(roundTrip(future), future);
    });

    test('FileRef', () {
      const file = FileRef('bucket', '/path/to/file');
      expect(roundTrip(file), file);
    });

    test('Range with string bounds preserves inclusivity', () {
      const range = Range(begin: BoundIncluded('a'), end: BoundExcluded('z'));
      expect(roundTrip(range), range);
    });

    test('RecordIdRange', () {
      const range = RecordIdRange('person',
          begin: BoundIncluded(1), end: BoundIncluded(100));
      expect(roundTrip(range), range);
    });
  });

  group('geometry', () {
    test('GeometryPoint', () {
      const point = GeometryPoint(-0.118092, 51.509865);
      expect(roundTrip(point), point);
    });

    test('GeometryLine', () {
      const line = GeometryLine([GeometryPoint(0, 0), GeometryPoint(1, 1)]);
      expect(roundTrip(line), line);
    });

    test('GeometryPolygon', () {
      const polygon = GeometryPolygon([
        GeometryLine([
          GeometryPoint(0, 0),
          GeometryPoint(1, 0),
          GeometryPoint(1, 1),
          GeometryPoint(0, 0),
        ]),
      ]);
      expect(roundTrip(polygon), polygon);
    });

    test('GeometryCollection', () {
      const collection = GeometryCollection([
        GeometryPoint(0, 0),
        GeometryLine([GeometryPoint(0, 0), GeometryPoint(1, 1)]),
      ]);
      expect(roundTrip(collection), collection);
    });
  });

  group('nested structures', () {
    test('a record with mixed values', () {
      final record = {
        'id': const RecordId('person', 'tobie'),
        'name': 'Tobie',
        'created': const SurrealDateTime(1718532000, 0),
        'scores': [1, 2, 3],
        'location': const GeometryPoint(0, 0),
      };
      expect(roundTrip(record), record);
    });
  });
}
