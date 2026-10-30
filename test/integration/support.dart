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

final Map<String, Future<List<int>>> _versions = {};

/// The `[major, minor]` version of the server at [url], read once.
Future<List<int>> serverVersion([String? url]) =>
    _versions.putIfAbsent(url ?? wsUrl, () async {
      final db = Surreal();
      await db.connect(url ?? wsUrl);
      try {
        final match =
            RegExp(r'(\d+)\.(\d+)\.\d+').firstMatch(await db.version());
        return [int.parse(match!.group(1)!), int.parse(match.group(2)!)];
      } finally {
        await db.close();
      }
    });

/// Whether the server is at least [major].[minor]. A test of a feature newer
/// than the oldest server in the CI matrix starts with
/// `if (!await serverAtLeast(3, 3)) return markTestSkipped('needs 3.3');`.
Future<bool> serverAtLeast(int major, int minor) async {
  final [serverMajor, serverMinor] = await serverVersion();
  return serverMajor > major || (serverMajor == major && serverMinor >= minor);
}
