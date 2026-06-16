import 'dart:typed_data';

/// The serialization formats the driver can speak to SurrealDB.
///
/// CBOR carries SurrealDB's rich types without loss and is the default. JSON is
/// easier to inspect on the wire but is lossy: record ids, datetimes,
/// durations, and decimals degrade to strings, and bytes to arrays. Decoded
/// JSON responses come back as plain maps, lists, strings, numbers, and bools
/// rather than the value types.
enum SurrealFormat { cbor, json }

/// Translates between Dart values and the bytes sent over an engine.
///
/// Implement this to provide a custom serialization. The built in
/// implementations are the CBOR and JSON codecs, selected through
/// [SurrealFormat].
abstract class SurrealCodec {
  /// The WebSocket subprotocol name for this codec, for example `cbor`.
  String get name;

  /// The HTTP content type for this codec, for example `application/cbor`.
  String get contentType;

  /// Whether the encoded form is binary. Text codecs are sent as WebSocket
  /// text frames, binary codecs as binary frames.
  bool get isBinary;

  /// Encodes a Dart value into bytes.
  Uint8List encode(Object? value);

  /// Decodes bytes into a Dart value.
  Object? decode(List<int> bytes);
}
