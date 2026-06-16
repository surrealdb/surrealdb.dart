import 'dart:convert' as convert;
import 'dart:typed_data';

import '../protocol/codec.dart';
import '../value/value.dart';

/// Translates between Dart values and JSON text.
///
/// On the way out, [SurrealValue] instances are written through their
/// [SurrealValue.toJson] form, which matches the string and GeoJSON
/// representations SurrealDB accepts over the JSON protocol. On the way back,
/// values come through as plain JSON: maps, lists, strings, numbers, and
/// booleans. JSON cannot carry the SurrealDB types without loss, so prefer the
/// CBOR codec unless you specifically need JSON on the wire.
class JsonCodec implements SurrealCodec {
  const JsonCodec();

  @override
  String get name => 'json';

  @override
  String get contentType => 'application/json';

  @override
  bool get isBinary => false;

  @override
  Uint8List encode(Object? value) => Uint8List.fromList(
        convert.utf8.encode(convert.jsonEncode(value, toEncodable: _encode)),
      );

  @override
  Object? decode(List<int> bytes) =>
      convert.jsonDecode(convert.utf8.decode(bytes));

  Object? _encode(Object? value) {
    if (value is SurrealValue) return value.toJson();
    if (value is DateTime) {
      return SurrealDateTime.fromDateTime(value).toString();
    }
    if (value is Duration) return SurrealDuration.fromDart(value).toString();
    if (value is BigInt) return value.toString();
    throw ArgumentError('Cannot encode value of type ${value.runtimeType}');
  }
}
