part of 'value.dart';

/// A UUID value. Backed by its 16 raw bytes, which is also how it is encoded on
/// the wire.
final class Uuid extends SurrealValue {
  /// Parses a UUID from its textual form, for example
  /// `8c6c5b1e-3a3a-4b3a-9b3a-1a2b3c4d5e6f`.
  Uuid(String text)
      : bytes = Uint8List.fromList(uuidlib.UuidParsing.parse(text));

  /// Wraps the given 16 raw bytes without copying any further.
  Uuid.fromBytes(this.bytes)
      : assert(bytes.length == 16, 'A UUID must be 16 bytes');

  /// Generates a random version 4 UUID.
  factory Uuid.v4() => Uuid(const uuidlib.Uuid().v4());

  /// Generates a time ordered version 7 UUID.
  factory Uuid.v7() => Uuid(const uuidlib.Uuid().v7());

  final Uint8List bytes;

  @override
  String toJson() => toString();

  @override
  String toString() => uuidlib.UuidParsing.unparse(bytes);

  @override
  bool operator ==(Object other) {
    if (other is! Uuid) return false;
    for (var i = 0; i < 16; i++) {
      if (other.bytes[i] != bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);
}
