part of 'value.dart';

/// The fixed-width number kinds of SurrealDB 4.0, next to its `int` (64-bit),
/// `float` (64-bit) and `decimal`.
enum SizedKind {
  i8,
  u8,
  i16,
  u16,
  i32,
  u32,
  u64,
  f16,
  f32;

  /// Whether this is an integer kind, `i8` to `u64`.
  bool get isInteger => index <= u64.index;
}

final _sizedIntRanges = <SizedKind, (BigInt, BigInt)>{
  SizedKind.i8: (BigInt.from(-128), BigInt.from(127)),
  SizedKind.u8: (BigInt.zero, BigInt.from(255)),
  SizedKind.i16: (BigInt.from(-32768), BigInt.from(32767)),
  SizedKind.u16: (BigInt.zero, BigInt.from(65535)),
  SizedKind.i32: (BigInt.from(-2147483648), BigInt.from(2147483647)),
  SizedKind.u32: (BigInt.zero, BigInt.from(4294967295)),
  SizedKind.u64: (BigInt.zero, (BigInt.one << 64) - BigInt.one),
};

/// An integer of one of SurrealDB 4.0's fixed-width kinds, `i8` to `u64`.
///
/// Over `cbor.2`, which a 4.0 server negotiates, it keeps its kind in both
/// directions. Over plain `cbor`, which is all a 3.x server speaks, it is sent
/// as a plain integer (a `u64` above the 64-bit signed range as a decimal),
/// and the server's value comes back as one.
///
/// SurrealDB compares a sized number equal to a plain one of the same value,
/// but here a `SizedInt` only equals another of the same kind and value.
final class SizedInt extends SurrealValue {
  /// An integer of [kind], which must be an integer kind and hold [value].
  SizedInt(this.kind, this.value) {
    if (!kind.isInteger) {
      throw ArgumentError.value(kind, 'kind', 'not an integer kind');
    }
    if (!holds(kind, value)) {
      throw RangeError('$value is outside the range of ${kind.name}');
    }
  }

  SizedInt.i8(int value) : this(SizedKind.i8, BigInt.from(value));
  SizedInt.u8(int value) : this(SizedKind.u8, BigInt.from(value));
  SizedInt.i16(int value) : this(SizedKind.i16, BigInt.from(value));
  SizedInt.u16(int value) : this(SizedKind.u16, BigInt.from(value));
  SizedInt.i32(int value) : this(SizedKind.i32, BigInt.from(value));
  SizedInt.u32(int value) : this(SizedKind.u32, BigInt.from(value));

  /// A `u64` from an [int]. Use the unnamed constructor with a [BigInt] for
  /// one above the 64-bit signed range.
  SizedInt.u64(int value) : this(SizedKind.u64, BigInt.from(value));

  final SizedKind kind;
  final BigInt value;

  /// Whether an integer of [kind] holds [value].
  static bool holds(SizedKind kind, BigInt value) {
    final range = _sizedIntRanges[kind];
    return range != null && value >= range.$1 && value <= range.$2;
  }

  /// The value as an [int]. A `u64` above the range of [int] is clamped.
  int toInt() => value.toInt();

  @override
  Object toJson() => value.bitLength <= 53 ? value.toInt() : '$value';

  /// The SurrealQL literal, such as `5u8`.
  @override
  String toString() => '$value${kind.name}';

  @override
  bool operator ==(Object other) =>
      other is SizedInt && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// A float of one of SurrealDB 4.0's narrow kinds, `f16` or `f32`.
///
/// The kind must hold the value exactly, as the server requires; any NaN will
/// do. Over plain `cbor` it is sent as a 64-bit float, as [SizedInt] is sent
/// as a plain integer.
final class SizedFloat extends SurrealValue {
  /// A float of [kind], which must be `f16` or `f32` and hold [value] exactly.
  SizedFloat(this.kind, this.value) {
    if (kind != SizedKind.f16 && kind != SizedKind.f32) {
      throw ArgumentError.value(kind, 'kind', 'not a float kind');
    }
    if (!holds(kind, value)) {
      throw ArgumentError.value(
          value, 'value', 'cannot be held exactly as ${kind.name}');
    }
  }

  SizedFloat.f16(double value) : this(SizedKind.f16, value);
  SizedFloat.f32(double value) : this(SizedKind.f32, value);

  final SizedKind kind;
  final double value;

  /// Whether a float of [kind] holds [value] exactly.
  static bool holds(SizedKind kind, double value) {
    if (value.isNaN || value.isInfinite) return true;
    return switch (kind) {
      SizedKind.f32 => (Float32List(1)..[0] = value)[0] == value,
      SizedKind.f16 => halfBits(value) != null,
      _ => false,
    };
  }

  /// The IEEE 754 half-precision bits of [value], or null when a half cannot
  /// hold it exactly.
  static int? halfBits(double value) {
    if (value.isNaN) return 0x7e00;
    final sign = value.isNegative ? 0x8000 : 0;
    final magnitude = value.abs();
    if (magnitude.isInfinite) return sign | 0x7c00;
    if (magnitude == 0) return sign;
    // A half is m * 2^(e - 25) with an 11-bit m, or a subnormal m * 2^-24.
    for (var exponent = -24; exponent <= 5; exponent++) {
      final scaled = magnitude / _pow2(exponent);
      if (scaled != scaled.truncateToDouble()) continue;
      final mantissa = scaled.toInt();
      if (mantissa >= 2048) continue;
      if (exponent == -24 && mantissa < 1024) return sign | mantissa;
      if (mantissa < 1024) continue;
      return sign | ((exponent + 25) << 10) | (mantissa - 1024);
    }
    return null;
  }

  static double _pow2(int exponent) {
    var result = 1.0;
    for (var i = 0; i < exponent.abs(); i++) {
      result = exponent < 0 ? result / 2 : result * 2;
    }
    return result;
  }

  @override
  Object toJson() => value;

  /// The SurrealQL literal, such as `1.5f32`.
  @override
  String toString() => '$value${kind.name}';

  @override
  bool operator ==(Object other) =>
      other is SizedFloat &&
      other.kind == kind &&
      (value.isNaN
          ? other.value.isNaN
          : other.value == value && other.value.isNegative == value.isNegative);

  @override
  int get hashCode => Object.hash(kind, value.isNaN ? 'NaN' : value);
}
