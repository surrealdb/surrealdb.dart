part of 'value.dart';

/// A point in time with nanosecond precision, held as whole seconds since the
/// Unix epoch plus a nanosecond remainder. Dart [DateTime] only reaches
/// microsecond precision, so converting to it rounds down.
final class SurrealDateTime extends SurrealValue {
  const SurrealDateTime(this.seconds, this.nanoseconds)
      : assert(nanoseconds >= 0 && nanoseconds < 1000000000,
            'nanoseconds must be in the range 0 to 999999999');

  /// Builds a value from a Dart [DateTime].
  ///
  /// Before 1970 the seconds are negative and the nanoseconds still count
  /// forwards from them, so one microsecond before the epoch is `-1` seconds
  /// plus 999999000 nanoseconds.
  factory SurrealDateTime.fromDateTime(DateTime value) {
    final micros = value.toUtc().microsecondsSinceEpoch;
    final remainder = micros % 1000000;
    return SurrealDateTime(
      (micros - remainder) ~/ 1000000,
      remainder * 1000,
    );
  }

  /// The current time.
  factory SurrealDateTime.now() => SurrealDateTime.fromDateTime(DateTime.now());

  /// Parses an RFC 3339 timestamp such as `2026-06-16T10:00:00Z`.
  factory SurrealDateTime.parse(String value) =>
      SurrealDateTime.fromDateTime(DateTime.parse(value));

  final int seconds;
  final int nanoseconds;

  /// Converts to a Dart [DateTime] in UTC, rounding down to microseconds.
  DateTime toDateTime() => DateTime.fromMicrosecondsSinceEpoch(
        seconds * 1000000 + nanoseconds ~/ 1000,
        isUtc: true,
      );

  /// The compact tuple form used by the CBOR codec: `[seconds, nanoseconds]`.
  List<int> toCompact() => [seconds, nanoseconds];

  @override
  String toJson() => toString();

  @override
  String toString() => toDateTime().toIso8601String();

  @override
  bool operator ==(Object other) =>
      other is SurrealDateTime &&
      other.seconds == seconds &&
      other.nanoseconds == nanoseconds;

  @override
  int get hashCode => Object.hash(seconds, nanoseconds);
}
