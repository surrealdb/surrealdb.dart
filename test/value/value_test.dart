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
}
