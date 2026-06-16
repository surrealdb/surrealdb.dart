import 'dart:convert';

import 'package:surrealdb/src/json/codec.dart';
import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  const codec = JsonCodec();

  Object? roundTrip(Object? value) => codec.decode(codec.encode(value));

  group('metadata', () {
    test('reports the json format', () {
      expect(codec.name, 'json');
      expect(codec.contentType, 'application/json');
      expect(codec.isBinary, isFalse);
    });
  });

  group('encoding', () {
    Object? encoded(Object? value) =>
        jsonDecode(utf8.decode(codec.encode(value)));

    test('plain values round trip', () {
      expect(
          roundTrip({
            'name': 'Tobie',
            'age': 32,
            'tags': [1, 2]
          }),
          {
            'name': 'Tobie',
            'age': 32,
            'tags': [1, 2]
          });
    });

    test('record ids encode as their string form', () {
      expect(encoded(const RecordId('person', 'tobie')), 'person:tobie');
    });

    test('datetimes encode as RFC 3339 strings', () {
      final dt = SurrealDateTime.fromDateTime(DateTime.utc(2026, 6, 16, 10));
      expect(encoded(dt), '2026-06-16T10:00:00.000Z');
    });

    test('durations encode as their string form', () {
      expect(encoded(SurrealDuration.minutes(90)), '1h30m');
    });

    test('decimals encode as strings', () {
      expect(encoded(const Decimal('3.14')), '3.14');
    });

    test('geometry encodes as GeoJSON', () {
      expect(encoded(const GeometryPoint(1, 2)), {
        'type': 'Point',
        'coordinates': [1, 2],
      });
    });

    test('a request envelope encodes as a JSON object', () {
      final bytes = codec.encode({
        'id': '1',
        'method': 'select',
        'params': [const RecordId('person', 'tobie')],
      });
      expect(jsonDecode(utf8.decode(bytes)), {
        'id': '1',
        'method': 'select',
        'params': ['person:tobie'],
      });
    });
  });
}
