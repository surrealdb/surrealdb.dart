import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  group('RecordId', () {
    test('formats simple ids', () {
      expect(const RecordId('person', 'tobie').toString(), 'person:tobie');
      expect(
          const RecordId('temperature', 9000).toString(), 'temperature:9000');
    });

    test('escapes ids with special characters', () {
      expect(const RecordId('person', 'tobie morgan').toString(),
          'person:`tobie morgan`');
    });

    test('equality', () {
      expect(
          const RecordId('person', 'tobie'), const RecordId('person', 'tobie'));
      expect(
          const RecordId('person', [1, 2]), const RecordId('person', [1, 2]));
    });
  });

  group('SurrealDuration', () {
    test('parses compound strings', () {
      final duration = SurrealDuration.parse('1w2d3h');
      expect(
        duration.seconds,
        7 * 86400 + 2 * 86400 + 3 * 3600,
      );
    });

    test('parses sub second units', () {
      final duration = SurrealDuration.parse('500ms');
      expect(duration.seconds, 0);
      expect(duration.nanoseconds, 500000000);
    });

    test('round trips through its string form', () {
      final duration = SurrealDuration.parse('2h30m');
      expect(SurrealDuration.parse(duration.toString()), duration);
    });

    test('rejects invalid input', () {
      expect(
          () => SurrealDuration.parse('not a duration'), throwsFormatException);
    });

    test('converts to and from Dart Duration', () {
      const source = Duration(hours: 1, minutes: 30);
      final duration = SurrealDuration.fromDart(source);
      expect(duration.toDart(), source);
    });
  });

  group('SurrealDateTime', () {
    test('converts from a Dart DateTime', () {
      final source = DateTime.utc(2026, 6, 16, 10);
      final dt = SurrealDateTime.fromDateTime(source);
      expect(dt.toDateTime(), source);
    });

    test('parses RFC 3339', () {
      final dt = SurrealDateTime.parse('2026-06-16T10:00:00Z');
      expect(dt.toDateTime(), DateTime.utc(2026, 6, 16, 10));
    });
  });

  group('Uuid', () {
    test('round trips through bytes', () {
      final uuid = Uuid('8c6c5b1e-3a3a-4b3a-9b3a-1a2b3c4d5e6f');
      expect(Uuid.fromBytes(uuid.bytes), uuid);
    });

    test('v4 produces 16 bytes', () {
      expect(Uuid.v4().bytes.length, 16);
    });
  });

  group('GeometryPoint', () {
    test('serialises to GeoJSON', () {
      expect(const GeometryPoint(1, 2).toJson(), {
        'type': 'Point',
        'coordinates': [1.0, 2.0],
      });
    });
  });

  group('times before the epoch', () {
    test('a datetime before 1970 keeps its seconds', () {
      final value = SurrealDateTime.fromDateTime(
          DateTime.utc(1969, 12, 31, 23, 59, 59, 500));
      expect(value.seconds, -1);
      expect(value.nanoseconds, 500000000);
      expect(value.toDateTime(), DateTime.utc(1969, 12, 31, 23, 59, 59, 500));
    });

    test('a datetime one microsecond before the epoch', () {
      final value = SurrealDateTime.fromDateTime(
          DateTime.fromMicrosecondsSinceEpoch(-1, isUtc: true));
      expect(value.seconds, -1);
      expect(value.nanoseconds, 999999000);
    });

    test('a whole-second datetime before 1970', () {
      final value = SurrealDateTime.fromDateTime(DateTime.utc(1900));
      expect(value.seconds, -2208988800);
      expect(value.nanoseconds, 0);
      expect(value.toString(), '1900-01-01T00:00:00.000Z');
    });

    test('a negative duration keeps its seconds', () {
      final value =
          SurrealDuration.fromDart(const Duration(milliseconds: -1500));
      expect(value.seconds, -2);
      expect(value.nanoseconds, 500000000);
      expect(value.toDart(), const Duration(milliseconds: -1500));
      expect(value.toString(), '-1s500ms');
      expect(value.isNegative, isTrue);
    });

    test('negative nanoseconds', () {
      final value = SurrealDuration.nanoseconds(-1);
      expect(value.seconds, -1);
      expect(value.nanoseconds, 999999999);
      expect(value.inNanoseconds, -1);
      expect(value.toString(), '-1ns');
    });
  });
}
