import 'dart:io';

import 'package:surrealdb/surrealdb.dart';

/// Shared configuration for the integration tests. They need a running
/// SurrealDB instance and only run when SURREAL_INTEGRATION is set.
final bool integrationEnabled =
    Platform.environment['SURREAL_INTEGRATION'] == '1';

/// The reason passed to `skip` when the integration tests are disabled.
final Object skipIntegration =
    integrationEnabled ? false : 'set SURREAL_INTEGRATION=1 to run';

final String wsUrl =
    Platform.environment['SURREAL_WS_URL'] ?? 'ws://127.0.0.1:8000/rpc';

final String httpUrl =
    Platform.environment['SURREAL_HTTP_URL'] ?? 'http://127.0.0.1:8000/rpc';

/// The connection URL for each engine, keyed by a readable name.
Map<String, String> get engineUrls => {'ws': wsUrl, 'http': httpUrl};

/// Connects to [url], signs in as root and selects the `test` namespace and
/// database, creating them when missing.
Future<Surreal> connectRoot(String url,
    {ConnectOptions options = const ConnectOptions()}) async {
  final db = Surreal();
  await db.connect(url, options: options);
  await db.signin(const RootAuth(username: 'root', password: 'root'));
  await db.query('DEFINE NAMESPACE IF NOT EXISTS test; '
      'USE NS test; DEFINE DATABASE IF NOT EXISTS test;');
  await db.use(namespace: 'test', database: 'test');
  return db;
}
