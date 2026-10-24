import 'package:surrealdb/src/cbor/reader.dart';
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

    test('integers beyond the 53-bit safe range become BigInt', () {
      // 0x1b ffffffffffffffff does not fit in an int on any platform.
      expect(
        codec.decode([0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
        BigInt.parse('18446744073709551615'),
      );
    });

    test('epoch datetimes keep whole seconds exact', () {
      // 1(1000000000001)
      expect(
        codec.decode([0xc1, 0x1b, 0, 0, 0, 0xe8, 0xd4, 0xa5, 0x10, 0x01]),
        const SurrealDateTime(1000000000001, 0),
      );
      expect(codec.decode([0xc1, 0x20]), const SurrealDateTime(-1, 0));
      // 1(1.5) and 1(-1.5)
      expect(codec.decode([0xc1, 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0]),
          const SurrealDateTime(1, 500000000));
      expect(codec.decode([0xc1, 0xfb, 0xbf, 0xf8, 0, 0, 0, 0, 0, 0]),
          const SurrealDateTime(-2, 500000000));
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

  group('what a 4.0 server accepts', () {
    // 4.0 refuses the text forms of datetimes (tag 0), uuids (tag 9) and
    // durations (tag 13), integers outside 64 bits, and tag 6 around
    // anything but null. Every server since 1.5.0 reads the forms the client
    // sends instead.
    Set<int> tagsIn(List<int> bytes) {
      final tags = <int>{};
      CborReader(bytes, (tag, value) {
        tags.add(tag);
        return value;
      }).readAll();
      return tags;
    }

    test('datetimes, uuids and durations never use the text tags', () {
      final uuid = Uuid('0192e3c4-0000-7000-8000-000000000001');
      final values = <Object?>[
        DateTime.utc(2024, 5, 6, 7, 8, 9, 10),
        const SurrealDateTime(-1, 999999999),
        const Duration(seconds: 5),
        const Duration(microseconds: -1),
        SurrealDuration.parse('1h30m'),
        uuid,
        RecordId('t', uuid),
        RecordId('t', DateTime.utc(2024)),
        RecordIdRange(
          't',
          begin: BoundIncluded(DateTime.utc(2024)),
          end: BoundExcluded(uuid),
        ),
        Range(
          begin: BoundIncluded(const Duration(seconds: 1)),
          end: BoundExcluded(DateTime.utc(2024)),
        ),
        {
          'at': DateTime.utc(2024),
          'for': [const Duration(seconds: 1), uuid],
          DateTime.utc(2025): uuid,
        },
        <Object?>{DateTime.utc(2024), const Duration(seconds: 1), uuid},
      ];
      for (final setsAsArrays in [false, true]) {
        final codec = CborCodec(setsAsArrays: setsAsArrays);
        for (final value in values) {
          expect(tagsIn(codec.encode(value)).intersection({0, 9, 13}), isEmpty,
              reason: '$value');
        }
      }
      expect(tagsIn(codec.encode(DateTime.utc(2024))), {12});
      expect(tagsIn(codec.encode(const Duration(seconds: 5))), {14});
      expect(tagsIn(codec.encode(uuid)), {37});
    });

    test('NONE is the only value under tag 6', () {
      expect(codec.encode([none, null, 0, '']),
          [0x84, 0xc6, 0xf6, 0xf6, 0x00, 0x60]);
    });

    test('integers inside 64 bits are sent as plain integers', () {
      expect(codec.encode(BigInt.from(5)), [0x05]);
      expect(
        codec.encode(BigInt.parse('9223372036854775807')),
        [0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
      );
      expect(
        codec.encode(BigInt.parse('-9223372036854775808')),
        [0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
      );
    });

    test('integers outside 64 bits are refused before they are sent', () {
      for (final value in [
        '9223372036854775808',
        '18446744073709551615',
        '18446744073709551616',
        '-9223372036854775809',
        '-18446744073709551617',
      ]) {
        expect(() => codec.encode(BigInt.parse(value)), throwsArgumentError,
            reason: value);
        expect(() => codec.encode([BigInt.parse(value)]), throwsArgumentError,
            reason: value);
      }
    });

    test('a decoded 64 bit unsigned integer cannot be sent back', () {
      final decoded =
          codec.decode([0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
      expect(() => codec.encode(decoded), throwsArgumentError);
    });
  });
}
