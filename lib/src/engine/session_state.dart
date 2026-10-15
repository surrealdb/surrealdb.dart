import '../errors.dart';
import '../value/value.dart';

/// Whether [error] is the server refusing the credentials or tokens it was
/// given, rather than failing to check them. Servers before 3.0 send no
/// kind, so their message is read instead.
bool rejectsAuthentication(Object error) {
  if (error is NotAllowedError) return true;
  if (error is! ServerError || error.rawKind != null) return false;
  final message = error.message.toLowerCase();
  return message.contains('authentication') || message.contains('token');
}

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

  String? _token;
  String? _refreshToken;
  final Map<String, Object?> variables = {};

  /// Called whenever the access or refresh token changes.
  void Function()? onTokensChanged;

  /// The access token the session is authenticated with.
  String? get token => _token;

  /// The refresh token issued with [token], if any.
  String? get refreshToken => _refreshToken;

  String? _expectedAccess;
  String? _expectedRefresh;

  /// Records that an `authenticate` call with [access] comes with
  /// [refresh], so that the call's success sets both tokens in one change.
  /// Pass nulls to forget it.
  void expectTokens(String? access, String? refresh) {
    _expectedAccess = access;
    _expectedRefresh = refresh;
  }

  /// Replaces both tokens at once.
  void setTokens(String? access, String? refresh) {
    if (access == _token && refresh == _refreshToken) return;
    _token = access;
    _refreshToken = refresh;
    onTokensChanged?.call();
  }

  /// Applies the effect of a successful [method] call with [params] that
  /// returned [result].
  void apply(String method, List<Object?> params, Object? result) {
    switch (method) {
      case 'use':
        applyUse(params, result);
      case 'signin':
      case 'signup':
      case 'refresh':
        setTokens(accessTokenOf(result), refreshTokenOf(result));
      case 'authenticate':
        final access = params.isNotEmpty ? params[0] as String? : null;
        // A refresh token given with the access token arrives with it.
        // Re-authenticating with the same token, as a reconnect does, keeps
        // its refresh token.
        final refresh = access != null && access == _expectedAccess
            ? _expectedRefresh
            : access == _token
                ? _refreshToken
                : null;
        setTokens(access, refresh);
      case 'invalidate':
        setTokens(null, null);
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
    setTokens(null, null);
    variables.clear();
  }

  /// Copies this state, for a forked session.
  SessionState copy() => SessionState()
    ..namespace = namespace
    ..database = database
    ..namespaceCleared = namespaceCleared
    ..databaseCleared = databaseCleared
    .._token = _token
    .._refreshToken = _refreshToken
    ..variables.addAll(variables);

  /// The refresh token in a `signin`, `signup` or `refresh` result, if any.
  static String? refreshTokenOf(Object? result) {
    final refresh = result is Map ? result['refresh'] : null;
    return refresh is String ? refresh : null;
  }

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
