part of 'value.dart';

/// One end of a [Range]. A bound is either inclusive or exclusive.
sealed class Bound {
  const Bound(this.value);

  final Object? value;

  @override
  bool operator ==(Object other) =>
      other is Bound &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// A bound that includes its value, for example the `1` in `1..=5`.
final class BoundIncluded extends Bound {
  const BoundIncluded(super.value);
}

/// A bound that excludes its value, for example the `5` in `1..5`.
final class BoundExcluded extends Bound {
  const BoundExcluded(super.value);
}

/// A range of values with an optional lower and upper [Bound]. A null bound
/// means the range is unbounded on that side.
final class Range extends SurrealValue {
  const Range({this.begin, this.end});

  final Bound? begin;
  final Bound? end;

  @override
  Object toJson() => {
        'begin': switch (begin) {
          null => null,
          BoundIncluded(:final value) => {'included': value},
          BoundExcluded(:final value) => {'excluded': value},
        },
        'end': switch (end) {
          null => null,
          BoundIncluded(:final value) => {'included': value},
          BoundExcluded(:final value) => {'excluded': value},
        },
      };

  @override
  bool operator ==(Object other) =>
      other is Range && other.begin == begin && other.end == end;

  @override
  int get hashCode => Object.hash(begin, end);
}
