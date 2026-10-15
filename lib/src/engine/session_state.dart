import '../value/value.dart';

/// The state of one server-side session, as the client knows it: the
/// selected namespace and database, the access token and the variables set
/// with `let`.
///
/// The engines keep it up to date from the calls that change it, so they
/// can replay it after a reconnect (WebSocket) or send it with every request
/// (HTTP).
class SessionState {
  String? namespace;
  String? database;

  /// Whether a null [namespace] or [database] was cleared, rather than never
  /// known: a `use` that kept a value the client did not know leaves it null
  /// too.
  bool namespaceCleared = false;
  bool databaseCleared = false;

  /// The namespace to select again after a reconnect: NONE, which keeps
  /// whatever the new session has, when it is not known.
  Object? get replayNamespace => namespace ?? (namespaceCleared ? null : none);

  /// The database to select again after a reconnect, like [replayNamespace].
  Object? get replayDatabase => database ?? (databaseCleared ? null : none);
  String? token;
  final Map<String, Object?> variables = {};

  /// Applies the effect of a successful [method] call with [params] that
  /// returned [result].
  void apply(String method, List<Object?> params, Object? result) {
    switch (method) {
      case 'use':
        applyUse(params, result);
      case 'signin':
      case 'signup':
        token = accessTokenOf(result);
      case 'authenticate':
        token = params.isNotEmpty ? params[0] as String? : null;
      case 'refresh':
        token = accessTokenOf(result);
      case 'invalidate':
        token = null;
      case 'let':
        final key = params[0] as String;
        // `let` without a value, or with NONE, removes the variable, as on
        // the server.
        final value = params.length > 1 ? params[1] : none;
        if (value is SurrealNone) {
          variables.remove(key);
        } else {
          // The engines pass the value as it was encoded, so later changes
          // to the caller's objects do not reach it.
          variables[key] = value;
        }
      case 'unset':
        variables.remove(params[0] as String);
      case 'reset':
        clear();
    }
  }

  /// Applies `use`. For each of the namespace and database a string selects
  /// it, null clears it and NONE (or a missing parameter) leaves it as it is.
  /// Clearing the namespace clears the database too. When the server reports
  /// what it selected, that wins.
  void applyUse(List<Object?> params, [Object? result]) {
    final ns = params.isNotEmpty ? params[0] : none;
    final db = params.length > 1 ? params[1] : none;
    if (ns is! SurrealNone) {
      namespace = ns as String?;
      namespaceCleared = ns == null;
      if (ns == null) {
        database = null;
        databaseCleared = true;
      }
    }
    if (db is! SurrealNone) {
      database = db as String?;
      databaseCleared = db == null;
    }
    if (result is Map) {
      if (result.containsKey('namespace')) {
        final value = result['namespace'];
        namespace = value is String ? value : null;
        namespaceCleared = namespace == null;
      }
      if (result.containsKey('database')) {
        final value = result['database'];
        database = value is String ? value : null;
        databaseCleared = database == null;
      }
    }
  }

  /// Forgets everything, as the server does on `reset`.
  void clear() {
    namespace = null;
    database = null;
    namespaceCleared = true;
    databaseCleared = true;
    token = null;
    variables.clear();
  }

  /// Copies this state, for a forked session.
  SessionState copy() => SessionState()
    ..namespace = namespace
    ..database = database
    ..namespaceCleared = namespaceCleared
    ..databaseCleared = databaseCleared
    ..token = token
    ..variables.addAll(variables);

  /// The access token in a `signin`, `signup` or `refresh` result: a bare
  /// string, `{access, refresh}` from 3.x, or `{token}` from older servers.
  static String? accessTokenOf(Object? result) {
    if (result is String) return result;
    if (result is Map) {
      for (final key in const ['access', 'token']) {
        if (result[key] is String) return result[key] as String;
      }
    }
    return null;
  }
}
