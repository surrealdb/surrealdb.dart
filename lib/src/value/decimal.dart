part of 'value.dart';

/// An arbitrary precision decimal number. The value is held as its textual
/// form so no precision is lost in transit.
final class Decimal extends SurrealValue {
  const Decimal(this.value);

  /// Builds a decimal from a Dart number. Note that doubles may already have
  /// lost precision before reaching this point.
  factory Decimal.fromNum(num value) => Decimal(value.toString());

  final String value;

  /// Parses the decimal into a Dart double. This may lose precision.
  double toDouble() => double.parse(value);

  @override
  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) => other is Decimal && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
