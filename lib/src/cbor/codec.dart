import 'dart:typed_data';

import 'package:cbor/cbor.dart';

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
class CborCodec implements SurrealCodec {
  const CborCodec();

  @override
  String get name => 'cbor';

  @override
  String get contentType => 'application/cbor';

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

  CborValue _toCbor(Object? value) {
    switch (value) {
      case null:
        return const CborNull();
      case bool():
        return CborBool(value);
      case int():
        return CborSmallInt(value);
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
    }
  }

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
  /// wraps. Nested tags have already been applied to [value].
  Object? _applyTag(int tag, Object? value) {
    switch (tag) {
      case SurrealCborTags.none:
        return null;
      case SurrealCborTags.table:
        return Table(value as String);
      case SurrealCborTags.recordId:
        if (value is String) return StringRecordId(value);
        final parts = value as List;
        final id = parts[1];
        if (id is Range) {
          return RecordIdRange(parts[0] as String,
              begin: id.begin, end: id.end);
        }
        return RecordId(parts[0] as String, id as Object);
      case SurrealCborTags.uuidString:
        return Uuid(value as String);
      case SurrealCborTags.uuidBinary:
        return Uuid.fromBytes(_asBytes(value));
      case SurrealCborTags.decimal:
        return Decimal(value as String);
      case SurrealCborTags.specDatetime:
        return SurrealDateTime.parse(value as String);
      case SurrealCborTags.epochDatetime:
        final seconds = _toDouble(value);
        return SurrealDateTime.fromDateTime(DateTime.fromMicrosecondsSinceEpoch(
            (seconds * 1000000).round(),
            isUtc: true));
      case SurrealCborTags.datetime:
        final parts = (value as List).cast<int>();
        return SurrealDateTime(
          parts.isNotEmpty ? parts[0] : 0,
          parts.length > 1 ? parts[1] : 0,
        );
      case SurrealCborTags.durationString:
        return SurrealDuration.parse(value as String);
      case SurrealCborTags.duration:
        final parts = (value as List).cast<int>();
        return SurrealDuration(
          seconds: parts.isNotEmpty ? parts[0] : 0,
          nanoseconds: parts.length > 1 ? parts[1] : 0,
        );
      case SurrealCborTags.future:
        return SurrealFuture(value as String);
      case SurrealCborTags.range:
        final parts = value as List;
        return Range(begin: _asBound(parts[0]), end: _asBound(parts[1]));
      case SurrealCborTags.boundIncluded:
        return BoundIncluded(value);
      case SurrealCborTags.boundExcluded:
        return BoundExcluded(value);
      case SurrealCborTags.file:
        final parts = (value as List).cast<String>();
        return FileRef(parts[0], parts[1]);
      case SurrealCborTags.set:
        return value;
      case SurrealCborTags.geometryPoint:
        final parts = value as List;
        return GeometryPoint(_toDouble(parts[0]), _toDouble(parts[1]));
      case SurrealCborTags.geometryLine:
        return GeometryLine((value as List).cast<GeometryPoint>());
      case SurrealCborTags.geometryPolygon:
        return GeometryPolygon((value as List).cast<GeometryLine>());
      case SurrealCborTags.geometryMultiPoint:
        return GeometryMultiPoint((value as List).cast<GeometryPoint>());
      case SurrealCborTags.geometryMultiLine:
        return GeometryMultiLine((value as List).cast<GeometryLine>());
      case SurrealCborTags.geometryMultiPolygon:
        return GeometryMultiPolygon((value as List).cast<GeometryPolygon>());
      case SurrealCborTags.geometryCollection:
        return GeometryCollection((value as List).cast<Geometry>());
      case SurrealCborTags.positiveBignum:
        return _bignum(_asBytes(value));
      case SurrealCborTags.negativeBignum:
        final n = _bignum(_asBytes(value));
        return n is int ? -1 - n : -BigInt.one - (n as BigInt);
      default:
        // An unknown tag is ignored and the inner value is returned as is.
        return value;
    }
  }

  static Object _bignum(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result.isValidInt ? result.toInt() : result;
  }

  /// Coerces a decoded range part into a [Bound]. The server always tags a
  /// bound as inclusive or exclusive; an untagged value is read as inclusive.
  Bound? _asBound(Object? value) {
    if (value == null) return null;
    if (value is Bound) return value;
    return BoundIncluded(value);
  }

  Uint8List _asBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw ArgumentError('Expected bytes, got ${value.runtimeType}');
  }

  double _toDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is BigInt) return value.toDouble();
    throw ArgumentError('Expected a number, got ${value.runtimeType}');
  }
}
