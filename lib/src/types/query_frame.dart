import '../errors.dart';

/// One piece of a streamed query result, from `queryStream`. Every frame
/// belongs to the statement at index [statement] in the query.
///
/// For each statement the stream gives, in order: the statement's result as
/// [QueryRows] batches (for a list result) or one [QueryValue] (for any other
/// result), then a [QueryStatementDone]. A statement that returns an empty
/// list has no [QueryRows].
sealed class QueryFrame {
  const QueryFrame(this.statement);

  /// The index of the statement in the query, from 0.
  final int statement;
}

/// A batch of rows from a statement that returns a list. Large results
/// arrive in several batches.
final class QueryRows extends QueryFrame {
  const QueryRows(super.statement, this.values);

  final List<Object?> values;

  @override
  String toString() => 'QueryRows($statement, ${values.length} rows)';
}

/// The result of a statement that does not return a list, such as
/// `RETURN 1`.
final class QueryValue extends QueryFrame {
  const QueryValue(super.statement, this.value);

  final Object? value;

  @override
  String toString() => 'QueryValue($statement, $value)';
}

/// The end of a statement.
///
/// When the statement failed, [error] is set, and any [QueryRows] already
/// received for it must be discarded: the statement had no effect.
final class QueryStatementDone extends QueryFrame {
  const QueryStatementDone(
    super.statement, {
    this.single = false,
    this.time,
    this.type,
    this.error,
  });

  /// Whether the statement's result was a single [QueryValue] rather than
  /// a list of [QueryRows].
  final bool single;

  /// How long the statement took, as the server formats it, e.g. `1.2ms`.
  final String? time;

  /// The kind of statement when it is special: `live` or `kill`.
  final String? type;

  /// The error, when the statement failed.
  final ServerError? error;

  /// Whether the statement succeeded.
  bool get ok => error == null;

  @override
  String toString() =>
      'QueryStatementDone($statement${error == null ? '' : ', $error'})';
}
