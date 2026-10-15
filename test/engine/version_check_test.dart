@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  group('isSupportedServerVersion', () {
    for (final (version, supported) in [
      ('surrealdb-3.3.4', true),
      ('3.4.0-nightly+20261014.4f7fa16', true),
      ('surrealdb-4.0.0', true),
      ('4.99.99', true),
      ('1.4.2', true),
      ('surrealdb-1.4.1', false),
      ('surrealdb-5.0.0', false),
      ('5.0.0-alpha.1', false),
      ('6.1.0', false),
      ('not a version', false),
    ]) {
      test('$version is ${supported ? '' : 'not '}supported', () {
        expect(isSupportedServerVersion(version), supported);
      });
    }
  });

  group('connect', () {
    late FakeSurrealServer server;

    setUp(() async => server = await FakeSurrealServer.start());
    tearDown(() async => server.close());

    FakeReply Function(FakeRequest) versionIs(String version) =>
        (request) => request.method == 'version'
            ? FakeResult(version)
            : FakeSurrealServer.defaultReply(request);

    test('rejects a 5.x server and closes the connection', () async {
      server.handler = versionIs('surrealdb-5.0.0');
      final db = Surreal();
      await expectLater(
        db.connect(server.url),
        throwsA(isA<UnsupportedVersionError>()
            .having((e) => e.version, 'version', 'surrealdb-5.0.0')),
      );
      expect(db.status, ConnectionStatus.disconnected);
      await eventually(() => server.openConnections == 0);
    });

    test('checks the version before signing in', () async {
      server.handler = versionIs('surrealdb-0.9.0');
      final db = Surreal();
      await expectLater(
        db.connect(server.url,
            options: const ConnectOptions(
                authentication: RootAuth(username: 'root', password: 'root'))),
        throwsA(isA<UnsupportedVersionError>()),
      );
      expect(server.methods, ['version']);
    });

    test('accepts a 4.x server', () async {
      server.handler = versionIs('surrealdb-4.0.0');
      final db = Surreal();
      await db.connect(server.url);
      expect(db.serverVersion, 'surrealdb-4.0.0');
      await db.close();
    });

    test('a reconnect to an unsupported server closes the client', () async {
      server.handler = versionIs('surrealdb-3.3.4');
      final db = Surreal();
      await db.connect(server.url,
          options: const ConnectOptions(
              reconnect: ReconnectOptions(
            retryDelay: Duration(milliseconds: 10),
            retryDelayMax: Duration(milliseconds: 10),
          )));
      final live = await db.live('person');
      final error = live.stream
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);

      server.handler = versionIs('surrealdb-5.0.0');
      await server.dropAll();
      expect(await error.timeout(const Duration(seconds: 5)),
          isA<UnsupportedVersionError>());
      await eventually(() => db.status == ConnectionStatus.disconnected);
      await eventually(() => server.openConnections == 0);
      expect(server.methods.where((m) => m == 'live'), hasLength(1));
    });

    test('an unsupported server is never reported as connected', () async {
      server.handler = versionIs('surrealdb-3.3.4');
      final db = Surreal();
      await db.connect(server.url,
          options: const ConnectOptions(
              reconnect: ReconnectOptions(
            retryDelay: Duration(milliseconds: 10),
            retryDelayMax: Duration(milliseconds: 10),
          )));
      await db.use(namespace: 'ns', database: 'db');
      final statuses = <ConnectionStatus>[];
      db.statusChanges.listen(statuses.add);
      server.requests.clear();

      server.handler = versionIs('surrealdb-5.0.0');
      await server.dropAll();
      await eventually(() => db.status == ConnectionStatus.disconnected);
      expect(statuses, isNot(contains(ConnectionStatus.connected)));
      // Nothing of the session was sent to it.
      expect(server.methods, ['version']);
    });

    test('a failed version check is a failed reconnect attempt', () async {
      server.handler = versionIs('surrealdb-3.3.4');
      final db = Surreal();
      addTearDown(db.close);
      await db.connect(server.url,
          options: const ConnectOptions(
              reconnect: ReconnectOptions(
            retryDelay: Duration(milliseconds: 10),
            retryDelayMax: Duration(milliseconds: 10),
          )));
      await db.live('person');

      var failures = 0;
      server.handler = (request) =>
          request.method == 'version' && failures++ < 2
              ? const FakeError('There was a problem with the database')
              : FakeSurrealServer.defaultReply(request);
      server.requests.clear();
      await server.dropAll();

      await eventually(() => server.methods.contains('live'));
      expect(db.status, ConnectionStatus.connected);
      expect(server.methods.where((m) => m == 'version'), hasLength(3));
      expect(server.accepted, 4);
    });

    test('can be turned off', () async {
      server.handler = versionIs('surrealdb-5.0.0');
      final db = Surreal();
      await db.connect(server.url,
          options: const ConnectOptions(versionCheck: false));
      expect(server.methods, isNot(contains('version')));
      await db.close();
    });
  });
}
