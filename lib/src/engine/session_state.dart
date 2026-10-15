import 'dart:convert';

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
      case 'refresh':
        token = accessTokenOf(result);
        _selectScopeOf(token);
      case 'authenticate':
        token = params.isNotEmpty ? params[0] as String? : null;
        _selectScopeOf(token);
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

  /// Records the namespace and database the server selects as it
  /// authenticates [token]: those its claims name, when it is a JWT.
  void _selectScopeOf(String? token) {
    final claims = token == null ? null : _claimsOf(token);
    if (claims == null) return;
    final ns = _claim(claims, const [
      'NS',
      'ns',
      'https://surrealdb.com/ns',
      'https://surrealdb.com/namespace',
    ]);
    final db = _claim(claims, const [
      'DB',
      'db',
      'https://surrealdb.com/db',
      'https://surrealdb.com/database',
    ]);
    if (ns is String) {
      namespace = ns;
      namespaceCleared = false;
    }
    if (db is String) {
      database = db;
      databaseCleared = false;
    }
  }

  /// The first of [names], the spellings the server accepts for a claim,
  /// that [claims] has.
  static Object? _claim(Map<Object?, Object?> claims, List<String> names) {
    for (final name in names) {
      if (claims.containsKey(name)) return claims[name];
    }
    return null;
  }

  /// The claims of a JWT, read without verifying it.
  static Map<Object?, Object?>? _claimsOf(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return claims is Map ? claims : null;
    } catch (_) {
      return null;
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

  /// Forgets everything, as the server does on `reset`. Unless [cleared], the
  /// namespace and database become unknown, as for a new connection, rather
  /// than cleared.
  void clear({bool cleared = true}) {
    namespace = null;
    database = null;
    namespaceCleared = cleared;
    databaseCleared = cleared;
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
