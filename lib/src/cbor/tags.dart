/// CBOR tag numbers used by the SurrealDB wire format.
///
/// These match the tags emitted and accepted by the SurrealDB server. Some
/// tags are decode only, meaning the server may send them but the client never
/// emits them. Those are noted below.
class SurrealCborTags {
  SurrealCborTags._();

  /// RFC 3339 datetime string. Decode only, the client emits [datetime].
  static const int specDatetime = 0;

  /// SurrealDB NONE, encoded as a tagged null.
  static const int none = 6;

  /// Table name.
  static const int table = 7;

  /// Record id, encoded as a two element array `[table, id]`.
  static const int recordId = 8;

  /// UUID as a string. Decode only, the client emits [uuidBinary].
  static const int uuidString = 9;

  /// Arbitrary precision decimal, as a string.
  static const int decimal = 10;

  /// Datetime as a compact `[seconds, nanoseconds]` array.
  static const int datetime = 12;

  /// Duration as a string. Decode only, the client emits [duration].
  static const int durationString = 13;

  /// Duration as a compact array.
  static const int duration = 14;

  /// Computed future, holding its body string.
  static const int future = 15;

  /// UUID as 16 raw bytes.
  static const int uuidBinary = 37;

  /// Range, encoded as a two element array `[beginBound, endBound]`.
  static const int range = 49;

  /// Inclusive range bound.
  static const int boundIncluded = 50;

  /// Exclusive range bound.
  static const int boundExcluded = 51;

  /// File pointer, encoded as `[bucket, key]`.
  static const int file = 55;

  /// Set, encoded as an array.
  static const int set = 56;

  static const int geometryPoint = 88;
  static const int geometryLine = 89;
  static const int geometryPolygon = 90;
  static const int geometryMultiPoint = 91;
  static const int geometryMultiLine = 92;
  static const int geometryMultiPolygon = 93;
  static const int geometryCollection = 94;
}
