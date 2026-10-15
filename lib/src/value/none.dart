part of 'value.dart';

/// The SurrealDB `NONE` value, the absence of a value, as distinct from
/// `NULL`, a value that is null.
///
/// Dart has a single `null`, so NONE has its own value, [none]. Dart `null`
/// is sent as NULL and [none] as NONE, and the codec decodes each back the
/// same way, so both round trip. A field set to [none] is removed when the
/// record is stored.
///
/// For convenience, a method that returns nothing at all, such as `use` or
/// `select` on a missing record, gives `null` rather than [none]. Values
/// inside a result, including the result of each statement in `query`, keep
/// [none].
final class SurrealNone extends SurrealValue {
  const SurrealNone._();

  /// JSON has no NONE, so it is written as null.
  @override
  Object? toJson() => null;

  @override
  String toString() => 'NONE';
}

/// The SurrealDB `NONE` value. See [SurrealNone].
const SurrealNone none = SurrealNone._();
