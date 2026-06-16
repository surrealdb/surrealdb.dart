import '../value/value.dart';

/// The kind of change a live query notification reports.
enum LiveAction {
  create,
  update,
  delete,

  /// Sent once when the live query is killed.
  killed;

  /// Parses the action string sent by the server, for example `CREATE`.
  /// Returns null for an action this client does not recognise.
  static LiveAction? tryParse(String value) {
    switch (value.toUpperCase()) {
      case 'CREATE':
        return LiveAction.create;
      case 'UPDATE':
        return LiveAction.update;
      case 'DELETE':
        return LiveAction.delete;
      case 'KILLED':
        return LiveAction.killed;
      default:
        return null;
    }
  }
}

/// A single notification delivered for a live query.
class LiveMessage {
  const LiveMessage({
    required this.queryId,
    required this.action,
    required this.value,
    this.recordId,
  });

  /// The id of the live query this notification belongs to.
  final Uuid queryId;

  /// What happened to the record.
  final LiveAction action;

  /// The record id the change applies to, when the server reports it.
  final RecordId? recordId;

  /// The record after the change, or the diff when the live query was started
  /// in diff mode.
  final Object? value;
}
