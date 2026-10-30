/// Typed JSON, the way the shared SurrealDB conformance vectors and scenarios
/// write values: plain JSON for the plain types, and a single-key object such
/// as `{"$uuid": "…"}` for every other type. See `spec/README.md` in
/// surrealdb-protocol.
library;

import 'dart:typed_data';

import 'package:surrealdb/surrealdb.dart';

const _sized = {
  r'$i8': SizedKind.i8,
  r'$u8': SizedKind.u8,
  r'$i16': SizedKind.i16,
  r'$u16': SizedKind.u16,
  r'$i32': SizedKind.i32,
  r'$u32': SizedKind.u32,
  r'$u64': SizedKind.u64,
  r'$f16': SizedKind.f16,
  r'$f32': SizedKind.f32,
};

const _typedKeys = {
  r'$none', r'$int', r'$float', r'$decimal', r'$string', r'$bytes', //
  r'$uuid', r'$datetime', r'$duration', r'$array', r'$object', r'$set',
  r'$table', r'$record', r'$range', r'$file', r'$geometry', r'$regex',
};

/// Reads typed JSON (as decoded from JSON or YAML) into the driver's values.
Object? fromTyped(Object? json) {
  switch (json) {
    case null || bool() || String() || int():
      return json;
    case double():
      // A bare float, as YAML writes one inside a geometry.
      return json;
    case List():
      return [for (final item in json) fromTyped(item)];
    case Map() when json.length == 1 && _isTypedKey(json.keys.single):
      return _typed(json.keys.single as String, json.values.single);
    case Map():
      return {
        for (final MapEntry(:key, :value) in json.entries)
          '$key': fromTyped(value),
      };
  }
  throw ArgumentError('Not typed JSON: $json');
}

bool _isTypedKey(Object? key) =>
    key is String && (_typedKeys.contains(key) || _sized.containsKey(key));

Object? _typed(String key, Object? arg) {
  final sized = _sized[key];
  if (sized != null) {
    return sized.isInteger
        ? SizedInt(sized, BigInt.parse('$arg'))
        : SizedFloat(sized, _float(arg));
  }
  switch (key) {
    case r'$none':
      return none;
    case r'$int':
      final n = BigInt.parse('$arg');
      return n.isValidInt ? n.toInt() : n;
    case r'$float':
      return _float(arg);
    case r'$decimal':
      return Decimal('$arg');
    case r'$string':
      return '$arg';
    case r'$bytes':
      final hex = '$arg';
      return Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    case r'$uuid':
      return Uuid('$arg');
    case r'$datetime':
      return SurrealDateTime.parse('$arg');
    case r'$duration':
      final [seconds, nanos] = arg! as List;
      return SurrealDuration(
          seconds: int.parse('$seconds'), nanoseconds: int.parse('$nanos'));
    case r'$array':
      return [for (final item in arg! as List) fromTyped(item)];
    case r'$object':
      return {
        for (final MapEntry(:key, :value) in (arg! as Map).entries)
          '$key': fromTyped(value),
      };
    case r'$set':
      return {for (final item in arg! as List) fromTyped(item)};
    case r'$table':
      return Table('$arg');
    case r'$record':
      final record = arg! as Map;
      final table = '${record['table']}';
      final id = fromTyped(record['key']);
      if (id is Range) {
        return RecordIdRange(table, begin: id.begin, end: id.end);
      }
      return RecordId(table, id!);
    case r'$range':
      final range = arg! as Map;
      return Range(begin: _bound(range['start']), end: _bound(range['end']));
    case r'$file':
      final file = arg! as Map;
      return FileRef('${file['bucket']}', '${file['key']}');
    case r'$geometry':
      return _geometry(arg! as Map);
  }
  throw UnsupportedError('No Dart value for $key');
}

double _float(Object? arg) => switch (arg) {
      num() => arg.toDouble(),
      'NaN' => double.nan,
      'Infinity' => double.infinity,
      '-Infinity' => double.negativeInfinity,
      '-0' => -0.0,
      _ => double.parse('$arg'),
    };

Bound? _bound(Object? json) {
  if (json == null) return null;
  final bound = json as Map;
  if (bound.containsKey('included')) {
    return BoundIncluded(fromTyped(bound['included']));
  }
  return BoundExcluded(fromTyped(bound['excluded']));
}

Geometry _geometry(Map<Object?, Object?> json) {
  GeometryPoint point(Object? c) {
    final [x, y] = c! as List;
    return GeometryPoint((x as num).toDouble(), (y as num).toDouble());
  }

  GeometryLine line(Object? c) =>
      GeometryLine([for (final p in c! as List) point(p)]);
  GeometryPolygon polygon(Object? c) =>
      GeometryPolygon([for (final l in c! as List) line(l)]);

  final coordinates = json['coordinates'];
  return switch (json['type']) {
    'Point' => point(coordinates),
    'LineString' => line(coordinates),
    'Polygon' => polygon(coordinates),
    'MultiPoint' =>
      GeometryMultiPoint([for (final p in coordinates as List) point(p)]),
    'MultiLineString' =>
      GeometryMultiLine([for (final l in coordinates as List) line(l)]),
    'MultiPolygon' =>
      GeometryMultiPolygon([for (final p in coordinates as List) polygon(p)]),
    'GeometryCollection' => GeometryCollection([
        for (final g in json['geometries'] as List)
          _geometry(g as Map<Object?, Object?>),
      ]),
    _ => throw ArgumentError('Unknown geometry ${json['type']}'),
  };
}

/// Writes a driver value as typed JSON.
Object? toTyped(Object? value) {
  switch (value) {
    case null || bool() || String():
      return value;
    case int():
      return value.abs() <= 9007199254740991 ? value : {r'$int': '$value'};
    case BigInt():
      return {r'$int': '$value'};
    case double():
      return {r'$float': _floatJson(value)};
    case Uint8List():
      return {
        r'$bytes':
            [for (final b in value) b.toRadixString(16).padLeft(2, '0')].join(),
      };
    case Set():
      return {
        r'$set': [for (final item in value) toTyped(item)]
      };
    case List():
      return [for (final item in value) toTyped(item)];
    case Map():
      final object = {
        for (final MapEntry(:key, :value) in value.entries)
          '$key': toTyped(value),
      };
      // An object that would read as a typed value is wrapped.
      return object.length == 1 && _isTypedKey(object.keys.single)
          ? {r'$object': object}
          : object;
    case SurrealNone():
      return {r'$none': null};
    case SizedInt(:final kind, :final value):
      return {
        '\$${kind.name}': value.isValidInt && value.toInt().abs() < 1 << 53
            ? value.toInt()
            : '$value',
      };
    case SizedFloat(:final kind, :final value):
      return {'\$${kind.name}': _floatJson(value)};
    case Decimal(:final value):
      return {r'$decimal': value};
    case Uuid():
      return {r'$uuid': '$value'};
    case SurrealDateTime():
      return {r'$datetime': _datetimeJson(value)};
    case SurrealDuration(:final seconds, :final nanoseconds):
      return {
        r'$duration': [seconds, nanoseconds]
      };
    case Table(:final name):
      return {r'$table': name};
    case RecordId(:final table, :final id):
      return {
        r'$record': {'table': table, 'key': toTyped(id)}
      };
    case RecordIdRange(:final table, :final begin, :final end):
      return {
        r'$record': {
          'table': table,
          'key': {
            r'$range': {'start': _boundJson(begin), 'end': _boundJson(end)}
          },
        }
      };
    case Range(:final begin, :final end):
      return {
        r'$range': {'start': _boundJson(begin), 'end': _boundJson(end)}
      };
    case FileRef(:final bucket, :final key):
      return {
        r'$file': {'bucket': bucket, 'key': key}
      };
    case Geometry():
      return {r'$geometry': value.toJson()};
  }
  return '$value';
}

Object _floatJson(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value > 0 ? 'Infinity' : '-Infinity';
  if (value == 0 && value.isNegative) return '-0';
  return value;
}

Object? _boundJson(Bound? bound) => switch (bound) {
      null => null,
      BoundIncluded(:final value) => {'included': toTyped(value)},
      BoundExcluded(:final value) => {'excluded': toTyped(value)},
    };

/// RFC 3339 in UTC, with nine fractional digits when there are nanoseconds.
String _datetimeJson(SurrealDateTime value) {
  final whole =
      DateTime.fromMillisecondsSinceEpoch(value.seconds * 1000, isUtc: true);
  final text = whole.toIso8601String();
  final base = text.substring(0, text.indexOf('.'));
  if (value.nanoseconds == 0) return '${base}Z';
  return '$base.${'${value.nanoseconds}'.padLeft(9, '0')}Z';
}

/// Whether two driver values are the same SurrealDB value: sets regardless of
/// order, NaN equal to NaN, and -0.0 apart from 0.0.
bool sameValue(Object? a, Object? b) {
  switch ((a, b)) {
    case (final double a, final double b):
      return a.isNaN ? b.isNaN : a == b && a.isNegative == b.isNegative;
    case (int() || BigInt(), int() || BigInt()):
      return '$a' == '$b';
    case (final List<Object?> a, final List<Object?> b):
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!sameValue(a[i], b[i])) return false;
      }
      return true;
    case (final Set<Object?> a, final Set<Object?> b):
      return a.length == b.length &&
          a.every((x) => b.any((y) => sameValue(x, y)));
    case (final Map<Object?, Object?> a, final Map<Object?, Object?> b):
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && sameValue(a[k], b[k]));
    case (final RecordId a, final RecordId b):
      return a.table == b.table && sameValue(a.id, b.id);
    case (final RecordIdRange a, final RecordIdRange b):
      return a.table == b.table &&
          _sameBound(a.begin, b.begin) &&
          _sameBound(a.end, b.end);
    case (final Range a, final Range b):
      return _sameBound(a.begin, b.begin) && _sameBound(a.end, b.end);
  }
  return a.runtimeType == b.runtimeType && a == b;
}

bool _sameBound(Bound? a, Bound? b) =>
    a.runtimeType == b.runtimeType &&
    (a == null || sameValue(a.value, b!.value));
