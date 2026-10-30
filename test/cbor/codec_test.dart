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

    test('a BigInt within 64 bits is an integer', () {
      final max = (BigInt.one << 63) - BigInt.one;
      final min = -(BigInt.one << 63);
      // A 64-bit unsigned and a 64-bit negative CBOR integer.
      expect(codec.encode(max), [0x1b, 0x7f, ...List.filled(7, 0xff)]);
      expect(codec.encode(min), [0x3b, 0x7f, ...List.filled(7, 0xff)]);
    });

    test('a BigInt beyond 64 bits is a decimal', () {
      final above = BigInt.one << 63;
      final below = -(BigInt.one << 63) - BigInt.one;
      final huge = BigInt.parse('12345678901234567890123456789');
      expect(roundTrip(above), Decimal('$above'));
      expect(roundTrip(below), Decimal('$below'));
      expect(roundTrip(huge), Decimal('$huge'));
      // Tag 10 over the digits.
      expect(codec.encode(above).take(2), [0xca, 0x73]);
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

    test('StringRecordId decodes as the record id it names', () {
      const id = StringRecordId('person:tobie');
      expect(roundTrip(id), const RecordId('person', 'tobie'));
    });

    test('a StringRecordId goes on the wire as text', () {
      // Tag 8 over the text `person:1`, for the server to parse, rather than
      // tag 8 over a [table, key] pair resolved here. Keeping the text form is
      // the whole point of StringRecordId.
      expect(codec.encode(const StringRecordId('person:1')),
          [0xc8, 0x68, ...'person:1'.codeUnits]);
      expect(codec.encode(const RecordId('person', '1')).take(2), [0xc8, 0x82]);
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

  group('range bounds', () {
    test('exclusive integer bounds stay exclusive', () {
      // 49([50(1), 51(5)]), the server's encoding of 1..5
      final decoded =
          codec.decode([0xd8, 49, 0x82, 0xd8, 50, 0x01, 0xd8, 51, 0x05]);
      expect(
        decoded,
        const Range(begin: BoundIncluded(1), end: BoundExcluded(5)),
      );
    });

    test('exclusive bounds round trip', () {
      for (final range in const [
        Range(begin: BoundExcluded(1), end: BoundIncluded(5)),
        Range(begin: BoundExcluded(-3), end: BoundExcluded(4000000000)),
        Range(end: BoundExcluded(5)),
        Range(begin: BoundExcluded(1.5)),
      ]) {
        expect(roundTrip(range), range);
      }
    });

    test('a record id range keeps its exclusive bound', () {
      const range = RecordIdRange('person',
          begin: BoundIncluded(1), end: BoundExcluded(10));
      expect(roundTrip(range), range);
    });
  });

  group('decoder', () {
    test('integers of every width', () {
      for (final value in [
        0,
        23,
        24,
        255,
        256,
        65535,
        65536,
        4294967295,
        4294967296,
        9007199254740991,
        -1,
        -24,
        -25,
        -256,
        -65537,
        -4294967297,
      ]) {
        expect(roundTrip(value), value, reason: '$value');
      }
    });

    test('integers keep all 64 bits', () {
      // On the web, beyond the 53-bit safe range, this is a BigInt.
      expect(
        '${codec.decode([0x1b, 0x7f, ...List.filled(7, 0xff)])}',
        '9223372036854775807',
      );
      expect(
        '${codec.decode([0x3b, 0x7f, ...List.filled(7, 0xff)])}',
        '-9223372036854775808',
      );
    });

    test('integers beyond 64 bits are refused', () {
      expect(() => codec.decode([0x1b, ...List.filled(8, 0xff)]),
          throwsFormatException);
      expect(() => codec.decode([0x3b, 0x80, ...List.filled(7, 0)]),
          throwsFormatException);
    });

    test('tags the server refuses are refused', () {
      for (final bytes in [
        [0xc0, 0x60], // 0(""): a datetime as text
        [0xc1, 0x00], // 1(0): an epoch datetime
        [0xc2, 0x40], // 2(h''): a bignum
        [0xc9, 0x60], // 9(""): a uuid as text
        [0xcd, 0x60], // 13(""): a duration as text
        [0xd8, 0x63, 0xf6], // 99(null): unknown
      ]) {
        expect(() => codec.decode(bytes), throwsFormatException,
            reason: '$bytes');
      }
    });

    test('floats of every width', () {
      expect(codec.decode([0xf9, 0x3c, 0x00]), 1.0); // half
      expect(codec.decode([0xf9, 0xc4, 0x00]), -4.0); // half
      expect(codec.decode([0xfa, 0x47, 0xc3, 0x50, 0x00]), 100000.0); // single
      expect(roundTrip(1.1), 1.1); // double
    });

    test('indefinite length items', () {
      // [_ 1, [2]], {_ "a": 1}, (_ "ab" "c")
      expect(codec.decode([0x9f, 0x01, 0x81, 0x02, 0xff]), [
        1,
        [2]
      ]);
      expect(codec.decode([0xbf, 0x61, 0x61, 0x01, 0xff]), {'a': 1});
      expect(codec.decode([0x7f, 0x62, 0x61, 0x62, 0x61, 0x63, 0xff]), 'abc');
    });

    test('rejects truncated input', () {
      expect(() => codec.decode([0x82, 0x01]), throwsFormatException);
    });
  });

  group('NONE and NULL', () {
    test('NONE and NULL round trip as distinct values', () {
      expect(roundTrip(none), same(none));
      expect(roundTrip(null), isNull);
      expect(roundTrip([none, null]), [none, null]);
      expect(roundTrip({'a': none, 'b': null}), {'a': none, 'b': null});
    });

    test('NONE is tag 6 on null and NULL is a plain null', () {
      expect(codec.encode(none), [0xc6, 0xf6]);
      expect(codec.encode(null), [0xf6]);
      expect(codec.decode([0xc6, 0xf6]), same(none));
      expect(codec.decode([0xf6]), isNull);
    });
  });

  group('Set', () {
    test('a Set is tag 56 on an array', () {
      expect(codec.encode(<int>{1}), [0xd8, 56, 0x81, 0x01]);
    });

    test('round trips as a Set', () {
      final decoded = roundTrip(<Object?>{3, 'a', const RecordId('t', 1)});
      expect(decoded, isA<Set<Object?>>());
      expect(decoded, <Object?>{3, 'a', const RecordId('t', 1)});
    });

    test('a List stays a List', () {
      expect(roundTrip([1, 1]), isA<List<Object?>>());
    });
  });
}
