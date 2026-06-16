part of 'value.dart';

/// A SurrealQL computed future, holding the body expression that the server
/// evaluates. Named [SurrealFuture] to avoid a clash with the Dart `Future`
/// type from `dart:async`.
final class SurrealFuture extends SurrealValue {
  const SurrealFuture(this.body);

  final String body;

  @override
  String toJson() => toString();

  @override
  String toString() => '<future> { $body }';

  @override
  bool operator ==(Object other) =>
      other is SurrealFuture && other.body == body;

  @override
  int get hashCode => body.hashCode;
}
