/// A driver for the conformance scenarios in surrealdb-protocol, which runs
/// them through this SDK's public API.
///
/// The scenario runner starts this process once per scenario and transport
/// and talks to it in JSON lines: `{"id":1,"op":"query","args":{...}}` in,
/// `{"id":1,"ok":true,"result":...}` or `{"id":1,"ok":false,"error":{...}}`
/// out. An op the SDK has no API for answers `Unsupported`, which the runner
/// reports as a skip. Values cross the pipe as typed JSON.
///
/// From a checkout of surrealdb-protocol, with this driver compiled:
///
/// ```sh
/// dart compile exe -DSDK_VERSION=0.1.0 tool/conformance_driver.dart \
///   -o build/conformance_driver
/// bun conformance/runner/cli.ts --driver "$SDK/build/conformance_driver"
/// ```
///
/// The SDK speaks `cbor.2` to a server that offers it (SurrealDB 4.0), so
/// sized numbers keep their width. Set `CONFORMANCE_CBOR=cbor` to speak plain
/// `cbor` instead, as `query-sized-numbers-widen-over-plain-cbor` expects.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:surrealdb/surrealdb.dart';

import '../test/conformance/typed_json.dart';

const _ops = [
  'connect', 'close', 'version', 'signin', 'signup', 'authenticate', //
  'invalidate', 'info', 'use', 'set', 'unset', 'query', 'query_stream', 'run',
  'live', 'live_of', 'live_id', 'next_notification', 'kill', 'new_session',
  'fork_session', 'list_sessions', 'close_session', 'begin', 'commit',
  'cancel', 'import', 'export',
];

Future<void> main() async {
  final driver = _Driver();
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, Object?>;
    final id = request['id'];
    final op = request['op']! as String;
    final args = (request['args'] as Map?)?.cast<String, Object?>() ?? {};
    Map<String, Object?> response;
    if (op == 'hello') {
      response = {
        'id': id,
        'ok': true,
        'result': {
          'name': 'surrealdb.dart',
          'version': _version(),
          'ops': _ops
        },
      };
    } else {
      try {
        response = {
          'id': id,
          'ok': true,
          'result': await driver.call(op, args)
        };
      } catch (e) {
        response = {'id': id, 'ok': false, 'error': _errorInfo(e)};
      }
    }
    stdout.writeln(jsonEncode(response));
  }
  // stdin closed: the scenario is over. Give the SDK a second to close the
  // connection, then exit, or the open connection keeps the process alive.
  await driver.db.close().timeout(const Duration(seconds: 1), onTimeout: () {});
  exit(0);
}

/// The SDK's version: `-DSDK_VERSION=...` when compiled, or else from the
/// pubspec next to this script.
String _version() {
  const compiled = String.fromEnvironment('SDK_VERSION');
  if (compiled.isNotEmpty) return compiled;
  final pubspec = File.fromUri(Platform.script.resolve('../pubspec.yaml'));
  if (!pubspec.existsSync()) return 'unknown';
  final match = RegExp(r'^version:\s*(\S+)', multiLine: true)
      .firstMatch(pubspec.readAsStringSync());
  return match?.group(1) ?? 'unknown';
}

/// Whether to speak plain `cbor` even to a server that offers `cbor.2`, as
/// the scenarios that expect sized numbers widened assume.
final _plainCbor = Platform.environment['CONFORMANCE_CBOR'] == 'cbor';

/// The CBOR codec without negotiation, which only the SDK's own codec does.
class _PlainCbor extends CborCodec {
  const _PlainCbor();
}

class _DriverError implements Exception {
  _DriverError(this.kind, this.message);

  final String kind;
  final String message;
}

_DriverError _unsupported(String what) =>
    _DriverError('Unsupported', 'surrealdb.dart has no API for $what');

class _Subscription {
  _Subscription(this.query, this.session) {
    _listener = query.stream.listen((message) {
      queue.add(message);
      _wake();
    }, onDone: () {
      done = true;
      _wake();
    }, onError: (Object _) {
      done = true;
      _wake();
    });
  }

  final LiveQuery query;

  /// The handle of the session it was started in; null is the default one.
  final String? session;
  final Queue<LiveMessage> queue = Queue();
  late final StreamSubscription<LiveMessage> _listener;
  Completer<void>? _waiting;
  var done = false;

  void _wake() {
    _waiting?.complete();
    _waiting = null;
  }

  Future<LiveMessage?> next(Duration timeout) async {
    if (queue.isEmpty && !done) {
      final waiting = _waiting = Completer();
      await waiting.future.timeout(timeout, onTimeout: () => _waiting = null);
    }
    return queue.isEmpty ? null : queue.removeFirst();
  }

  Future<void> cancel() => _listener.cancel();
}

class _Driver {
  Surreal db = Surreal();
  final _sessions = <String, SurrealSession>{};
  final _txns = <String, SurrealTransaction>{};
  // The session handle each transaction was begun in; null is the default.
  final _txnSessions = <String, String?>{};
  final _subs = <String, _Subscription>{};
  var _nextHandle = 1;

  SurrealSessionMethods _session(Object? handle) {
    if (handle == null) return db;
    return _sessions[handle] ??
        (throw _DriverError('NotFound', 'no session $handle'));
  }

  /// Where a query runs: the transaction, or else the session.
  SurrealQueryable _scope(Map<String, Object?> args) {
    final txn = args['txn'];
    if (txn == null) return _session(args['session']);
    final t =
        _txns[txn] ?? (throw _DriverError('NotFound', 'no transaction $txn'));
    // A transaction belongs to its session: naming another one is a lookup
    // that fails, as it does on the server.
    if (args['session'] != _txnSessions[txn]) {
      throw _DriverError(
          'NotFound', 'no transaction $txn in session ${args['session']}');
    }
    return t;
  }

  /// The session for an op the SDK has only on a session. A `txn` is refused
  /// rather than ignored, so the op never runs outside the transaction the
  /// scenario asked for.
  SurrealSessionMethods _sessionOnly(String op, Map<String, Object?> args) {
    if (args['txn'] != null) throw _unsupported('$op in a transaction');
    return _session(args['session']);
  }

  _Subscription _sub(Map<String, Object?> args) =>
      _subs[args['subscription']] ??
      (throw _DriverError('NotFound', 'no such subscription'));

  String _subscribe(LiveQuery query, Object? session) {
    final handle = 'live-${_nextHandle++}';
    _subs[handle] = _Subscription(query, session as String?);
    return handle;
  }

  String _keep(SurrealSession session) {
    final handle = '${session.id}';
    _sessions[handle] = session;
    return handle;
  }

  Future<Object?> call(String op, Map<String, Object?> args) async {
    switch (op) {
      case 'connect':
        await db.close().catchError((_) {});
        db = Surreal();
        // Handles from the old connection must not reach the new one.
        for (final sub in _subs.values) {
          await sub.cancel();
        }
        _sessions.clear();
        _txns.clear();
        _txnSessions.clear();
        _subs.clear();
        await db.connect(args['url']! as String,
            options: ConnectOptions(
                reconnect: ReconnectOptions.disabled,
                codec: _plainCbor ? const _PlainCbor() : null));
        return null;
      case 'close':
        await db.close();
        return null;
      case 'version':
        final version = await db.version();
        return version.startsWith('surrealdb-')
            ? version
            : 'surrealdb-$version';
      case 'signin':
        final credentials =
            (args['credentials']! as Map).cast<String, Object?>();
        return _tokens(
            await _sessionOnly(op, args).signin(_signinAuth(credentials)));
      case 'signup':
        final credentials =
            (args['credentials']! as Map).cast<String, Object?>();
        return _tokens(
            await _sessionOnly(op, args).signup(_signupAuth(credentials)));
      case 'authenticate':
        final session = _sessionOnly(op, args);
        switch (args['token']) {
          case final String token:
            await session.authenticate(token);
          // The tokens signin returned, with or without a refresh token.
          case {'access': final String access} &&
                final Map<Object?, Object?> tokens:
            await session.authenticate(access,
                refreshToken: tokens['refresh'] as String?);
          case final token:
            throw _DriverError('Validation', 'not a token: $token');
        }
        return null;
      case 'invalidate':
        await _sessionOnly(op, args).invalidate();
        return null;
      case 'info':
        return toTyped(await _sessionOnly(op, args).info());
      case 'use':
        final session = _sessionOnly(op, args);
        // A key left out keeps its value; a key given as null clears it.
        if (args.containsKey('namespace') && args.containsKey('database')) {
          await session.use(
              namespace: args['namespace'] as String?,
              database: args['database'] as String?);
        } else if (args.containsKey('namespace')) {
          await session.use(namespace: args['namespace'] as String?);
        } else if (args.containsKey('database')) {
          await session.use(database: args['database'] as String?);
        }
        return {'namespace': session.namespace, 'database': session.database};
      case 'set':
        await _sessionOnly(op, args)
            .set(args['name']! as String, fromTyped(args['value']));
        return null;
      case 'unset':
        await _sessionOnly(op, args).unset(args['name']! as String);
        return null;
      case 'query':
        final statements = await _scope(args)
            .queryRaw(args['sql']! as String, bindings: _vars(args));
        return [
          for (final (index, statement) in statements.indexed)
            statement['status'] == 'OK'
                ? {'ok': true, 'result': toTyped(statement['result'])}
                : {
                    'ok': false,
                    'error': _errorInfo(
                        ServerError.fromStatement(statement, index: index)),
                  },
        ];
      case 'query_stream':
        final results = <int, Object?>{};
        final rows = <int, List<Object?>>{};
        await for (final frame in _scope(args)
            .queryStream(args['sql']! as String, bindings: _vars(args))) {
          switch (frame) {
            case QueryRows(:final statement, :final values):
              (rows[statement] ??= []).addAll(values);
            case QueryValue(:final statement, :final value):
              results[statement] = {'ok': true, 'result': toTyped(value)};
            case QueryStatementDone(:final statement, :final error?):
              rows.remove(statement);
              results[statement] = {'ok': false, 'error': _errorInfo(error)};
            case QueryStatementDone(:final statement):
              results[statement] ??= {
                'ok': true,
                'result': toTyped(rows[statement] ?? const []),
              };
          }
        }
        return [for (var i = 0; i < results.length; i++) results[i]];
      case 'run':
        return toTyped(await _scope(args).run(
          args['name']! as String,
          version: args['version'] as String?,
          args: [for (final a in (args['args'] as List?) ?? []) fromTyped(a)],
        ));
      case 'live':
        final query = await _sessionOnly(op, args)
            .live(Table(args['table']! as String), diff: args['diff'] == true);
        return _subscribe(query, args['session']);
      case 'live_of':
        final id = fromTyped(args['id']);
        return _subscribe(
            _sessionOnly(op, args)
                .liveOf(id is Uuid ? id : Uuid(id.toString())),
            args['session']);
      case 'live_id':
        return toTyped(_sub(args).query.id);
      case 'next_notification':
        final timeout = (args['timeout'] as num?)?.toInt() ?? 5000;
        final message = await _sub(args).next(Duration(milliseconds: timeout));
        if (message == null) return null;
        if (message.action == LiveAction.killed) return {'action': 'KILLED'};
        return {
          'action': message.action.name.toUpperCase(),
          'record': toTyped(message.recordId),
          'result': toTyped(message.value),
        };
      case 'kill':
        // A live query has no kill in a transaction, and is killed in the
        // session it was started in, so refuse any other context.
        if (args['txn'] != null) throw _unsupported('kill in a transaction');
        final sub = _sub(args);
        if (args['session'] != sub.session) {
          throw _unsupported(
              "kill from a session other than the subscription's");
        }
        await sub.query.kill();
        return null;
      case 'new_session':
        return _keep(await db.newSession());
      case 'fork_session':
        return _keep(await _session(args['from']).forkSession());
      case 'list_sessions':
        return [for (final id in await db.sessions()) '$id'];
      case 'close_session':
        final session = _sessionOnly(op, args);
        if (session is! SurrealSession) {
          throw _unsupported('closing the default session');
        }
        await session.close();
        _sessions.remove(args['session']);
        return null;
      case 'begin':
        final handle = 'txn-${_nextHandle++}';
        _txns[handle] = await _sessionOnly(op, args).beginTransaction();
        _txnSessions[handle] = args['session'] as String?;
        return handle;
      case 'commit' || 'cancel':
        // The handle stays valid: using a finished transaction is a scenario
        // too.
        final txn = _scope(args) as SurrealTransaction;
        await (op == 'commit' ? txn.commit() : txn.cancel());
        return null;
      // The SDK imports and exports through the connection, outside any
      // session or transaction, so refuse a context rather than ignore it.
      case 'import':
        if (args['session'] != null || args['txn'] != null) {
          throw _unsupported('import in a session or transaction');
        }
        await db.import(args['surql']! as String);
        return null;
      case 'export':
        if (args['session'] != null || args['txn'] != null) {
          throw _unsupported('export in a session or transaction');
        }
        return db.export(options: _exportOptions(args['options'] as Map?));
    }
    throw _unsupported(op);
  }
}

Map<String, Object?>? _vars(Map<String, Object?> args) =>
    (fromTyped(args['vars']) as Map?)?.cast<String, Object?>();

Object? _tokens(Tokens tokens) => {
      'access': tokens.access,
      if (tokens.refresh != null) 'refresh': tokens.refresh,
    };

/// The wire's signin keys (user, pass, ns, db, ac, and record variables) as
/// the SDK's credentials.
AnyAuth _signinAuth(Map<String, Object?> c) {
  final namespace = c['ns'] as String?;
  final database = c['db'] as String?;
  final access = c['ac'] as String?;
  final user = c['user'] as String?;
  final pass = c['pass'] as String? ?? '';
  if (access == null) {
    if (user == null) throw _unsupported('signin without a user or access');
    if (namespace == null) return RootAuth(username: user, password: pass);
    if (database == null) {
      return NamespaceAuth(
          namespace: namespace, username: user, password: pass);
    }
    return DatabaseAuth(
        namespace: namespace,
        database: database,
        username: user,
        password: pass);
  }
  if (user != null) {
    return AccessSystemAuth(
        access: access,
        username: user,
        password: pass,
        namespace: namespace,
        database: database);
  }
  if (c['key'] case final String key) {
    return AccessBearerAuth(
        access: access, key: key, namespace: namespace, database: database);
  }
  // Record access: every other key, `pass` included, is a variable for the
  // access method's SIGNIN clause.
  return _recordAuth(c);
}

/// Signup is record access only: ns, db and ac pick the access method, and
/// every other key is a variable for its SIGNUP clause.
AccessRecordAuth _signupAuth(Map<String, Object?> c) => _recordAuth(c);

AccessRecordAuth _recordAuth(Map<String, Object?> c) => AccessRecordAuth(
      access: c['ac']! as String,
      namespace: c['ns'] as String?,
      database: c['db'] as String?,
      variables: {
        for (final MapEntry(:key, :value) in c.entries)
          if (key != 'ns' && key != 'db' && key != 'ac') key: fromTyped(value),
      },
    );

ExportOptions? _exportOptions(Map<dynamic, dynamic>? o) {
  if (o == null) return null;
  final unknown = o.keys.toSet().difference(const {
    'users', 'accesses', 'params', 'functions', 'analyzers', 'apis', //
    'buckets', 'modules', 'configs', 'tables', 'versions', 'records',
    'sequences',
  });
  if (unknown.isNotEmpty) throw _unsupported('export option $unknown');
  return ExportOptions(
    users: o['users'] as bool?,
    accesses: o['accesses'] as bool?,
    params: o['params'] as bool?,
    functions: o['functions'] as bool?,
    analyzers: o['analyzers'] as bool?,
    apis: o['apis'] as bool?,
    buckets: o['buckets'] as bool?,
    modules: o['modules'] as bool?,
    configs: o['configs'] as bool?,
    tables: switch (o['tables']) {
      null => null,
      true => ExportTables.all,
      false => ExportTables.none,
      final List<Object?> names => ExportTables.only(names.cast()),
      final other => throw _DriverError('Validation', 'tables: $other'),
    },
    versions: o['versions'] as bool?,
    records: o['records'] as bool?,
    sequences: o['sequences'] as bool?,
  );
}

Map<String, Object?> _errorInfo(Object e) {
  switch (e) {
    case _DriverError(:final kind, :final message):
      return {'kind': kind, 'message': message};
    // The SDK refuses a finished transaction itself, where the server would
    // answer Validation.
    case TransactionClosedError(:final message):
      return {'kind': 'Validation', 'message': message};
    case UnsupportedFeatureError(:final message):
      return {'kind': 'Unsupported', 'message': message};
    case ImportError(:final message, :final failures):
      return {
        'kind': 'Query',
        'message': message,
        'failures': [for (final f in failures) _errorInfo(f)],
      };
    case HttpConnectionError(:final statusCode, :final message):
      // Plain HTTP endpoints (/import, /export) answer with a status, not a
      // kind.
      return {
        'kind': switch (statusCode) {
          401 || 403 => 'NotAllowed',
          404 => 'NotFound',
          _ => 'Validation',
        },
        'message': message,
      };
    case ServerError(:final rawKind, :final kind, :final message):
      return {
        'kind': rawKind ?? kind.wireName,
        'message': message,
        if (e.details case final details?) 'details': _detail(details),
        if (e.code case final code? when code != 0) 'code': code,
      };
  }
  return {'kind': 'Internal', 'message': '$e'};
}

Object? _detail(ErrorDetail detail) => {
      'kind': detail.kind,
      if (detail.inner case final inner?)
        'details': _detail(inner)
      else if (detail.fields.isNotEmpty)
        'details': {
          for (final MapEntry(:key, :value) in detail.fields.entries)
            key: toTyped(value),
        },
    };
