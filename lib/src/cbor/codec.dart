import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../engine/rpc.dart' show parseRecordId;
import '../protocol/codec.dart';
import '../value/value.dart';
import 'reader.dart';
import 'tags.dart';

/// Translates between Dart values and the CBOR wire format used by SurrealDB.
///
/// On the way out, [SurrealValue] instances become tagged CBOR values and plain
/// Dart values (maps, lists, strings, numbers, booleans, bytes) map to their
/// CBOR counterparts. On the way back, tagged values are rebuilt into the
/// matching [SurrealValue]. This is the default codec, since CBOR carries the
/// SurrealDB types without loss.
///
/// It speaks two dialects. Plain `cbor` is what every server speaks. `cbor.2`
/// adds SurrealDB 4.0's sized numbers ([SizedInt] and [SizedFloat]) as tags
/// 180 to 188, and is otherwise the same byte for byte. The engines offer
/// `cbor.2` and switch to it when the server accepts it, so a 3.x server
/// keeps getting plain `cbor`.
///
/// Decoding is as strict as a SurrealDB 4.0 server's: input it would refuse,
/// such as an unknown tag or an integer beyond 64 bits, is a
/// [FormatException] rather than a guess.
class CborCodec implements SurrealCodec {
  const CborCodec({this.setsAsArrays = false, this.sizedNumbers = false});

  /// Whether Dart sets are encoded as plain arrays rather than as SurrealDB
  /// sets. Servers before 3.0 have no set type and reject the set tag, so
  /// the client turns this on when it connects to one.
  final bool setsAsArrays;

  /// Whether this codec speaks `cbor.2`, which carries sized numbers as tags
  /// 180 to 188. Plain `cbor` sends them widened, as an integer, float or
  /// (a `u64` beyond 64-bit signed) decimal, and refuses the tags.
  final bool sizedNumbers;

  /// A copy of this codec with the given settings changed.
  CborCodec copyWith({bool? setsAsArrays, bool? sizedNumbers}) => CborCodec(
        setsAsArrays: setsAsArrays ?? this.setsAsArrays,
        sizedNumbers: sizedNumbers ?? this.sizedNumbers,
      );

  /// The WebSocket subprotocol: `cbor`, or `cbor.2` with [sizedNumbers].
  @override
  String get name => sizedNumbers ? 'cbor.2' : 'cbor';

  /// The HTTP media type: `application/cbor`, with `v=2` for [sizedNumbers].
  @override
  String get contentType =>
      sizedNumbers ? 'application/cbor; v=2' : 'application/cbor';

  @override
  bool get isBinary => true;

  /// Encodes a Dart value into CBOR bytes.
  @override
  Uint8List encode(Object? value) =>
      Uint8List.fromList(cborEncode(_toCbor(value)));

  /// Decodes CBOR bytes into a Dart value.
  @override
  Object? decode(List<int> bytes) => CborReader(bytes, _applyTag).readAll();

  // ---------------------------------------------------------------------------
  // Encoding
  // ---------------------------------------------------------------------------

  static final _i64Min = -(BigInt.one << 63);
  static final _i64Max = (BigInt.one << 63) - BigInt.one;

  CborValue _toCbor(Object? value) {
    switch (value) {
      case null:
        return const CborNull();
      case bool():
        return CborBool(value);
      case int():
        return CborSmallInt(value);
      case BigInt() when value < _i64Min || value > _i64Max:
        // SurrealDB integers are 64-bit, so a larger one is sent as a decimal,
        // which keeps it exact. As a CBOR integer a 3.x server would wrap it
        // and a 4.0 server refuses it.
        return CborString('$value', tags: const [SurrealCborTags.decimal]);
      case BigInt():
        return CborInt(value);
      case double():
        return CborFloat(value);
      case String():
        return CborString(value);
      case Uint8List():
        return CborBytes(value);
      case DateTime():
        return _toCbor(SurrealDateTime.fromDateTime(value));
      case Duration():
        return _toCbor(SurrealDuration.fromDart(value));
      case SurrealValue():
        return _valueToCbor(value);
      case Map():
        return CborMap({
          for (final entry in value.entries)
            _toCbor(entry.key): _toCbor(entry.value),
        });
      case Set() when setsAsArrays:
        return CborList([for (final item in value) _toCbor(item)]);
      case Set():
        return CborList(
          [for (final item in value) _toCbor(item)],
          tags: const [SurrealCborTags.set],
        );
      case Iterable():
        return CborList([for (final item in value) _toCbor(item)]);
    }
    throw ArgumentError('Cannot encode value of type ${value.runtimeType}');
  }

  CborValue _valueToCbor(SurrealValue value) {
    switch (value) {
      case Table(:final name):
        return CborString(name, tags: const [SurrealCborTags.table]);
      case RecordId(:final table, :final id):
        return CborList(
          [CborString(table), _toCbor(id)],
          tags: const [SurrealCborTags.recordId],
        );
      case StringRecordId(:final value):
        return CborString(value, tags: const [SurrealCborTags.recordId]);
      case RecordIdRange(:final table, :final begin, :final end):
        return CborList(
          [CborString(table), _encodeRange(begin, end)],
          tags: const [SurrealCborTags.recordId],
        );
      case Range(:final begin, :final end):
        return _encodeRange(begin, end);
      case Uuid(:final bytes):
        return CborBytes(bytes, tags: const [SurrealCborTags.uuidBinary]);
      case Decimal(:final value):
        return CborString(value, tags: const [SurrealCborTags.decimal]);
      case SurrealDateTime():
        return CborList(
          [for (final part in value.toCompact()) CborSmallInt(part)],
          tags: const [SurrealCborTags.datetime],
        );
      case SurrealDuration():
        return CborList(
          [for (final part in value.toCompact()) CborSmallInt(part)],
          tags: const [SurrealCborTags.duration],
        );
      case SurrealFuture(:final body):
        return CborString(body, tags: const [SurrealCborTags.future]);
      case FileRef(:final bucket, :final key):
        return CborList(
          [CborString(bucket), CborString(key)],
          tags: const [SurrealCborTags.file],
        );
      case Geometry():
        return _geometryToCbor(value);
      case SurrealNone():
        return const CborNull(tags: [SurrealCborTags.none]);
      case SizedInt(:final kind, :final value):
        // Widened, a u64 beyond 64-bit signed becomes a decimal.
        if (!sizedNumbers) return _toCbor(value);
        return CborInt(value, tags: [_sizedTags[kind.index]]);
      case SizedFloat(:final kind, :final value):
        if (!sizedNumbers) return CborFloat(value);
        return CborFloat(value, tags: [_sizedTags[kind.index]]);
    }
  }

  /// The tag of each [SizedKind], in order.
  static const _sizedTags = [
    SurrealCborTags.i8,
    SurrealCborTags.u8,
    SurrealCborTags.i16,
    SurrealCborTags.u16,
    SurrealCborTags.i32,
    SurrealCborTags.u32,
    SurrealCborTags.u64,
    SurrealCborTags.f16,
    SurrealCborTags.f32,
  ];

  CborValue _encodeRange(Bound? begin, Bound? end) => CborList(
        [_encodeBound(begin), _encodeBound(end)],
        tags: const [SurrealCborTags.range],
      );

  CborValue _encodeBound(Bound? bound) {
    switch (bound) {
      case null:
        return const CborNull();
      case BoundIncluded(:final value):
        return _prependTag(_toCbor(value), SurrealCborTags.boundIncluded);
      case BoundExcluded(:final value):
        return _prependTag(_toCbor(value), SurrealCborTags.boundExcluded);
    }
  }

  CborValue _geometryToCbor(Geometry geometry) {
    switch (geometry) {
      case GeometryPoint(:final longitude, :final latitude):
        return CborList(
          [CborFloat(longitude), CborFloat(latitude)],
          tags: const [SurrealCborTags.geometryPoint],
        );
      case GeometryLine(:final points):
        return CborList(
          [for (final p in points) _geometryToCbor(p)],
          tags: const [SurrealCborTags.geometryLine],
        );
      case GeometryPolygon(:final lines):
        return CborList(
          [for (final l in lines) _geometryToCbor(l)],
          tags: const [SurrealCborTags.geometryPolygon],
        );
      case GeometryMultiPoint(:final points):
        return CborList(
          [for (final p in points) _geometryToCbor(p)],
          tags: const [SurrealCborTags.geometryMultiPoint],
        );
      case GeometryMultiLine(:final lines):
        return CborList(
          [for (final l in lines) _geometryToCbor(l)],
          tags: const [SurrealCborTags.geometryMultiLine],
        );
      case GeometryMultiPolygon(:final polygons):
        return CborList(
          [for (final p in polygons) _geometryToCbor(p)],
          tags: const [SurrealCborTags.geometryMultiPolygon],
        );
      case GeometryCollection(:final geometries):
        return CborList(
          [for (final g in geometries) _geometryToCbor(g)],
          tags: const [SurrealCborTags.geometryCollection],
        );
    }
  }

  CborValue _prependTag(CborValue value, int tag) {
    final tags = [tag, ...value.tags];
    switch (value) {
      case CborSmallInt():
        return CborSmallInt(value.toInt(), tags: tags);
      case CborInt():
        return CborInt(value.toBigInt(), tags: tags);
      case CborFloat():
        return CborFloat(value.value, tags: tags);
      case CborString():
        return CborString(value.toString(), tags: tags);
      case CborBytes():
        return CborBytes(value.bytes, tags: tags);
      case CborBool():
        return CborBool(value.value, tags: tags);
      case CborNull():
        return CborNull(tags: tags);
      case CborList():
        return CborList(value.toList(), tags: tags);
      case CborMap():
        return CborMap(value, tags: tags);
      default:
        throw ArgumentError('Cannot tag value of type ${value.runtimeType}');
    }
  }

  // ---------------------------------------------------------------------------
  // Decoding
  // ---------------------------------------------------------------------------

  /// Rebuilds the SurrealDB value for [tag] from the decoded [value] it
  /// wraps. Nested tags have already been applied to [value]. Anything a
  /// SurrealDB 4.0 server would refuse is a [FormatException].
  Object? _applyTag(int tag, Object? value) {
    switch (tag) {
      case SurrealCborTags.none:
        if (value != null) {
          throw _invalid(tag, 'holds something other than null');
        }
        return none;
      case SurrealCborTags.table:
        return Table(_string(tag, value));
      case SurrealCborTags.recordId:
        return _recordId(value);
      case SurrealCborTags.uuidBinary:
        final bytes = _bytes(tag, value);
        if (bytes.length != 16) throw _invalid(tag, 'is not 16 bytes');
        return Uuid.fromBytes(bytes);
      case SurrealCborTags.decimal:
        return _decimal(_string(tag, value));
      case SurrealCborTags.datetime:
        final [seconds, nanos] = _ints(tag, value, 2, 2);
        if (nanos < 0 || nanos >= _nanosPerSecond) {
          throw _invalid(tag, 'has nanoseconds out of range');
        }
        if (seconds < _minDatetime || seconds > _maxDatetime) {
          throw _invalid(tag, 'is outside the range of a datetime');
        }
        return SurrealDateTime(seconds, nanos);
      case SurrealCborTags.duration:
        final parts = _ints(tag, value, 0, 2);
        if (parts.any((part) => part < 0)) {
          throw _invalid(tag, 'is negative');
        }
        final seconds = parts.isEmpty ? 0 : parts[0];
        final nanos = parts.length > 1 ? parts[1] : 0;
        return SurrealDuration(
          seconds: seconds + nanos ~/ _nanosPerSecond,
          nanoseconds: nanos % _nanosPerSecond,
        );
      case SurrealCborTags.future:
        // Only servers before 3.0 send futures.
        return SurrealFuture(_string(tag, value));
      case SurrealCborTags.range:
        final parts = _list(tag, value);
        if (parts.length != 2) throw _invalid(tag, 'is not two bounds');
        return Range(begin: _bound(parts[0]), end: _bound(parts[1]));
      case SurrealCborTags.boundIncluded:
        return BoundIncluded(value);
      case SurrealCborTags.boundExcluded:
        return BoundExcluded(value);
      case SurrealCborTags.file:
        final parts = _list(tag, value);
        if (parts.length != 2 || parts.any((part) => part is! String)) {
          throw _invalid(tag, 'is not a bucket and a key');
        }
        return FileRef(parts[0] as String, parts[1] as String);
      case SurrealCborTags.set:
        return <Object?>{..._list(tag, value)};
      case SurrealCborTags.geometryPoint:
        final parts = _list(tag, value);
        if (parts.length != 2) throw _invalid(tag, 'is not two coordinates');
        return GeometryPoint(_coordinate(parts[0]), _coordinate(parts[1]));
      case SurrealCborTags.geometryLine:
        return GeometryLine(_all<GeometryPoint>(tag, value));
      case SurrealCborTags.geometryPolygon:
        final lines = _all<GeometryLine>(tag, value);
        if (lines.isEmpty) throw _invalid(tag, 'has no rings');
        return GeometryPolygon([for (final line in lines) _closed(line)]);
      case SurrealCborTags.geometryMultiPoint:
        return GeometryMultiPoint(_all<GeometryPoint>(tag, value));
      case SurrealCborTags.geometryMultiLine:
        return GeometryMultiLine(_all<GeometryLine>(tag, value));
      case SurrealCborTags.geometryMultiPolygon:
        return GeometryMultiPolygon(_all<GeometryPolygon>(tag, value));
      case SurrealCborTags.geometryCollection:
        return GeometryCollection(_all<Geometry>(tag, value));
      case >= SurrealCborTags.i8 && <= SurrealCborTags.f32:
        if (!sizedNumbers) {
          throw FormatException('CBOR tag $tag is a sized number, which only '
              'cbor.2 carries');
        }
        final kind = SizedKind.values[tag - SurrealCborTags.i8];
        if (kind.isInteger) {
          final n = value is BigInt ? value : BigInt.from(value! as int);
          if (!SizedInt.holds(kind, n)) {
            throw _invalid(tag, 'holds $n, outside the range of ${kind.name}');
          }
          return SizedInt(kind, n);
        }
        final f = value! as double;
        if (!SizedFloat.holds(kind, f)) {
          throw _invalid(tag, 'holds $f, which ${kind.name} cannot hold');
        }
        return SizedFloat(kind, f);
      default:
        // Refused and unknown tags alike, as the server does.
        throw FormatException('CBOR tag $tag is not accepted');
    }
  }

  static const int _nanosPerSecond = 1000000000;

  /// The datetimes the server can hold, from -262143-01-01 to
  /// +262142-12-31T23:59:59.999999999Z, in seconds since the epoch.
  static const int _minDatetime = -8334601228800;
  static const int _maxDatetime = 8210266876799;

  static FormatException _invalid(int tag, String problem) =>
      FormatException('CBOR tag $tag $problem');

  static String _string(int tag, Object? value) =>
      value is String ? value : throw _invalid(tag, 'is not a string');

  static List<Object?> _list(int tag, Object? value) =>
      value is List ? value : throw _invalid(tag, 'is not an array');

  static Uint8List _bytes(int tag, Object? value) =>
      value is Uint8List ? value : throw _invalid(tag, 'is not bytes');

  /// [value] as a list of [min] to [max] integers that fit in an [int].
  static List<int> _ints(int tag, Object? value, int min, int max) {
    final parts = _list(tag, value);
    if (parts.length < min || parts.length > max) {
      throw _invalid(tag, 'has ${parts.length} elements');
    }
    if (parts.any((part) => part is! int)) {
      throw _invalid(tag, 'holds something other than an integer');
    }
    return parts.cast<int>();
  }

  static List<T> _all<T>(int tag, Object? value) {
    final items = _list(tag, value);
    if (items.any((item) => item is! T)) {
      throw _invalid(tag, 'holds something other than a $T');
    }
    return items.cast<T>();
  }

  /// A ring as the server keeps it, with the first point repeated at the end.
  static GeometryLine _closed(GeometryLine line) {
    final points = line.points;
    if (points.isEmpty || points.first == points.last) return line;
    return GeometryLine([...points, points.first]);
  }

  static double _coordinate(Object? value) => switch (value) {
        double() => value,
        int() => value.toDouble(),
        BigInt() => value.toDouble(),
        Decimal() => value.toDouble(),
        SizedInt() => value.value.toDouble(),
        SizedFloat() => value.value,
        _ => throw _invalid(SurrealCborTags.geometryPoint,
            'has a coordinate that is not a number'),
      };

  /// A bound of a range: tag 50 or 51, or null for an unbounded side.
  static Bound? _bound(Object? value) => switch (value) {
        null || Bound() => value as Bound?,
        _ => throw _invalid(SurrealCborTags.range, 'has an untagged bound'),
      };

  static Object _recordId(Object? value) {
    const tag = SurrealCborTags.recordId;
    if (value is String) {
      // Record id syntax, such as person:alice. The server never sends it.
      try {
        final id = parseRecordId(value);
        if (id != null) return id;
      } on FormatException {
        // Reported below.
      }
      throw _invalid(tag, 'holds text that is not a record id: $value');
    }
    final parts = _list(tag, value);
    if (parts.length != 2) throw _invalid(tag, 'is not a table and a key');
    final [table, key] = parts;
    if (table is! String) throw _invalid(tag, 'has a table that is not text');
    if (key is Range) {
      if (!_isKey(key.begin?.value) || !_isKey(key.end?.value)) {
        throw _invalid(tag, 'has a range bound that is no record id key');
      }
      return RecordIdRange(table, begin: key.begin, end: key.end);
    }
    if (!_isKey(key)) throw _invalid(tag, 'has a key of the wrong type');
    return RecordId(table, _plainKey(key)!);
  }

  /// Whether [key] can be a record id key (or a missing range bound).
  static bool _isKey(Object? key) => switch (key) {
        null || int() || String() || List() || Map() || Uuid() => true,
        BigInt() => false,
        SizedInt(:final value) => value >= _i64Min && value <= _i64Max,
        _ => false,
      };

  /// A sized integer key is a plain integer, as the server reads it.
  static Object? _plainKey(Object? key) =>
      key is SizedInt ? key.value.toInt() : key;

  static final _decimalSyntax = RegExp(r'^-?(\d+)(?:\.(\d+))?$');
  static final _decimalMantissaMax = (BigInt.one << 96) - BigInt.one;

  /// A decimal as the server holds it: at most a 96-bit mantissa and 28
  /// fractional digits, without trailing fractional zeros.
  static Decimal _decimal(String text) {
    const tag = SurrealCborTags.decimal;
    final match = _decimalSyntax.firstMatch(text);
    if (match == null) throw _invalid(tag, 'is not a decimal: $text');
    final whole = match.group(1)!;
    final fraction = (match.group(2) ?? '').replaceFirst(RegExp(r'0+$'), '');
    if (fraction.length > 28) throw _invalid(tag, 'has a scale above 28');
    if (BigInt.parse('$whole$fraction') > _decimalMantissaMax) {
      throw _invalid(tag, 'needs more than 96 bits');
    }
    final negative = text.startsWith('-');
    final digits = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    return Decimal(
        '${negative ? '-' : ''}$digits${fraction.isEmpty ? '' : '.$fraction'}');
  }
}
