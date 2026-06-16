part of 'value.dart';

const int _nanosPerSecond = 1000000000;
const int _nanosPerMicro = 1000;
const int _nanosPerMilli = 1000000;
const int _secondsPerMinute = 60;
const int _secondsPerHour = 3600;
const int _secondsPerDay = 86400;
const int _secondsPerWeek = 604800;

/// A length of time, held as whole seconds plus a nanosecond remainder. This
/// matches the precision SurrealDB uses and avoids the microsecond limit of
/// the Dart [Duration] type.
final class SurrealDuration extends SurrealValue {
  const SurrealDuration({this.seconds = 0, this.nanoseconds = 0})
      : assert(nanoseconds >= 0 && nanoseconds < _nanosPerSecond,
            'nanoseconds must be in the range 0 to 999999999');

  /// Builds a duration from a Dart [Duration]. Dart durations have microsecond
  /// precision, so the nanosecond remainder is always a multiple of 1000.
  factory SurrealDuration.fromDart(Duration duration) {
    final micros = duration.inMicroseconds;
    return SurrealDuration(
      seconds: micros ~/ 1000000,
      nanoseconds: (micros % 1000000) * _nanosPerMicro,
    );
  }

  factory SurrealDuration.nanoseconds(int value) => SurrealDuration(
        seconds: value ~/ _nanosPerSecond,
        nanoseconds: value % _nanosPerSecond,
      );

  factory SurrealDuration.microseconds(int value) =>
      SurrealDuration.nanoseconds(value * _nanosPerMicro);

  factory SurrealDuration.milliseconds(int value) =>
      SurrealDuration.nanoseconds(value * _nanosPerMilli);

  factory SurrealDuration.fromSeconds(int value) =>
      SurrealDuration(seconds: value);

  factory SurrealDuration.minutes(int value) =>
      SurrealDuration(seconds: value * _secondsPerMinute);

  factory SurrealDuration.hours(int value) =>
      SurrealDuration(seconds: value * _secondsPerHour);

  factory SurrealDuration.days(int value) =>
      SurrealDuration(seconds: value * _secondsPerDay);

  factory SurrealDuration.weeks(int value) =>
      SurrealDuration(seconds: value * _secondsPerWeek);

  /// Parses a SurrealDB duration string such as `1w2d3h`, `500ms` or `90s`.
  factory SurrealDuration.parse(String input) {
    if (input.isEmpty || input == '0' || input == '0ns') {
      return const SurrealDuration();
    }
    final matches = _durationPattern.allMatches(input);
    if (matches.isEmpty) {
      throw FormatException('Invalid duration', input);
    }
    var seconds = 0;
    var nanos = 0;
    var consumed = 0;
    for (final match in matches) {
      consumed += match.group(0)!.length;
      final amount = int.parse(match.group(1)!);
      switch (match.group(2)!) {
        case 'ns':
          nanos += amount;
        case 'us':
        case 'µs':
          nanos += amount * _nanosPerMicro;
        case 'ms':
          nanos += amount * _nanosPerMilli;
        case 's':
          seconds += amount;
        case 'm':
          seconds += amount * _secondsPerMinute;
        case 'h':
          seconds += amount * _secondsPerHour;
        case 'd':
          seconds += amount * _secondsPerDay;
        case 'w':
          seconds += amount * _secondsPerWeek;
      }
    }
    if (consumed != input.length) {
      throw FormatException('Invalid duration', input);
    }
    seconds += nanos ~/ _nanosPerSecond;
    nanos %= _nanosPerSecond;
    return SurrealDuration(seconds: seconds, nanoseconds: nanos);
  }

  final int seconds;
  final int nanoseconds;

  /// The whole duration expressed in nanoseconds.
  int get inNanoseconds => seconds * _nanosPerSecond + nanoseconds;

  /// Converts to a Dart [Duration], rounding down to microsecond precision.
  Duration toDart() => Duration(
        seconds: seconds,
        microseconds: nanoseconds ~/ _nanosPerMicro,
      );

  /// The compact tuple form used by the CBOR codec: an empty list for a zero
  /// duration, `[seconds]` when there is no nanosecond remainder, otherwise
  /// `[seconds, nanoseconds]`.
  List<int> toCompact() {
    if (seconds == 0 && nanoseconds == 0) return const [];
    if (nanoseconds == 0) return [seconds];
    return [seconds, nanoseconds];
  }

  @override
  String toJson() => toString();

  @override
  String toString() {
    if (seconds == 0 && nanoseconds == 0) return '0ns';
    final buffer = StringBuffer();
    var remaining = seconds;
    void unit(int size, String suffix) {
      if (remaining >= size) {
        buffer.write('${remaining ~/ size}$suffix');
        remaining %= size;
      }
    }

    unit(_secondsPerWeek, 'w');
    unit(_secondsPerDay, 'd');
    unit(_secondsPerHour, 'h');
    unit(_secondsPerMinute, 'm');
    if (remaining > 0) buffer.write('${remaining}s');

    var ns = nanoseconds;
    if (ns >= _nanosPerMilli) {
      buffer.write('${ns ~/ _nanosPerMilli}ms');
      ns %= _nanosPerMilli;
    }
    if (ns >= _nanosPerMicro) {
      buffer.write('${ns ~/ _nanosPerMicro}us');
      ns %= _nanosPerMicro;
    }
    if (ns > 0) buffer.write('${ns}ns');
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is SurrealDuration &&
      other.seconds == seconds &&
      other.nanoseconds == nanoseconds;

  @override
  int get hashCode => Object.hash(seconds, nanoseconds);
}

final RegExp _durationPattern = RegExp(r'(\d+)(ns|µs|us|ms|s|m|h|d|w)');
