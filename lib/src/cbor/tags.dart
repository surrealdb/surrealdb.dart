/// CBOR tag numbers used by the SurrealDB wire format.
///
/// These match the tags emitted and accepted by the SurrealDB server. Some
/// are refused: the server never sends them, and a 4.0 server rejects them, so
/// the client neither sends nor accepts them. Those are noted below.
class SurrealCborTags {
  SurrealCborTags._();

  /// RFC 3339 datetime string. Refused; the client sends [datetime].
  static const int specDatetime = 0;

  /// Datetime as seconds since the Unix epoch. Refused.
  static const int epochDatetime = 1;

  /// Unsigned integer too large for a CBOR integer, as big-endian bytes.
  /// Refused.
  static const int positiveBignum = 2;

  /// Negative integer too large for a CBOR integer, as big-endian bytes.
  /// Refused.
  static const int negativeBignum = 3;

  /// SurrealDB NONE, encoded as a tagged null.
  static const int none = 6;

  /// Table name.
  static const int table = 7;

  /// Record id, encoded as a two element array `[table, id]`.
  static const int recordId = 8;

  /// UUID as a string. Refused; the client sends [uuidBinary].
  static const int uuidString = 9;

  /// Arbitrary precision decimal, as a string.
  static const int decimal = 10;

  /// Datetime as a compact `[seconds, nanoseconds]` array.
  static const int datetime = 12;

  /// Duration as a string. Refused; the client sends [duration].
  static const int durationString = 13;

  /// Duration as a compact array.
  static const int duration = 14;

  /// Computed future, holding its body string. Servers before 3.0 have
  /// futures; later ones refuse the tag.
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

  /// Set, encoded as an array. A Dart [Set] is sent with this tag and the tag
  /// decodes to a [Set].
  static const int set = 56;

  static const int geometryPoint = 88;
  static const int geometryLine = 89;
  static const int geometryPolygon = 90;
  static const int geometryMultiPoint = 91;
  static const int geometryMultiLine = 92;
  static const int geometryMultiPolygon = 93;
  static const int geometryCollection = 94;

  /// SurrealDB 4.0's sized numbers, under `cbor.2` only: the integer kinds
  /// `i8` to `u64` (180 to 186), then the float kinds `f16` (187) and `f32`
  /// (188). Plain `cbor` refuses them.
  static const int i8 = 180;
  static const int u8 = 181;
  static const int i16 = 182;
  static const int u16 = 183;
  static const int i32 = 184;
  static const int u32 = 185;
  static const int u64 = 186;
  static const int f16 = 187;
  static const int f32 = 188;
}
