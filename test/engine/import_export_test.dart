@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

/// An HTTP server standing in for SurrealDB's `/rpc`, `/import` and
/// `/export` endpoints, to show how the client copes with older servers.
class _FakeHttpServer {
  _FakeHttpServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeHttpServer> start() async =>
      _FakeHttpServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  String version = 'surrealdb-3.3.4';
  int importStatus = 200;
  String importBody = '[]';
  bool exportTakesPost = true;
  final requests = <String>[];
  final exportBodies = <Object?>[];

  String get url => 'http://127.0.0.1:${_server.port}/rpc';

  Future<void> _handle(HttpRequest request) async {
    final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    requests.add('${request.method} ${request.uri.path}');
    final response = request.response;
    switch (request.uri.path) {
      case '/rpc':
        const codec = CborCodec();
        final call = codec.decode(body) as Map;
        response.headers.contentType = ContentType('application', 'cbor');
        response.add(codec.encode({
          'id': call['id'],
          'result': call['method'] == 'version' ? version : null,
        }));
      case '/import':
        response.statusCode = importStatus;
        response.headers.contentType = ContentType.json;
        response.write(importBody);
      case '/export':
        if (request.method == 'POST') {
          exportBodies.add(const CborCodec().decode(body));
        }
        if (request.method == 'POST' && !exportTakesPost) {
          response.statusCode = 405;
        } else {
          response.write('-- export');
        }
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _FakeHttpServer server;
  late Surreal db;

  setUp(() async {
    server = await _FakeHttpServer.start();
    db = Surreal();
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('an import whose reply says nothing is not reported as done', () async {
    server.importBody = '';
    await db.connect(server.url);
    await expectLater(
        db.import('OPTION IMPORT; CREATE a:1;'), throwsA(isA<ResponseError>()));
  });

  test('failures in a JSON reply listing every statement are reported',
      () async {
    server.importBody = jsonEncode([
      {'status': 'OK', 'result': []},
      {'status': 'ERR', 'result': 'Database record `a:1` already exists'},
    ]);
    await db.connect(server.url);
    await expectLater(
      db.import('OPTION IMPORT; CREATE b:1; CREATE a:1;'),
      throwsA(isA<ImportError>()
          .having((e) => e.failures.single.statementIndex, 'index', 1)),
    );
  });

  test('export options are not sent to a server before 2.1', () async {
    server
      ..version = 'surrealdb-2.0.5'
      ..exportTakesPost = false;
    await db.connect(server.url);
    final dump = await db.export(options: const ExportOptions(accesses: false));
    expect(dump, '-- export');
    expect(server.requests, isNot(contains('POST /export')));
  });

  test('versions is only sent to an export on a server before 3.0', () async {
    const options = ExportOptions(versions: true, records: false);
    await db.connect(server.url);
    await db.export(options: options);
    await db.close();

    server.version = 'surrealdb-2.3.10';
    db = Surreal();
    await db.connect(server.url);
    await db.export(options: options);

    expect(server.exportBodies, [
      {'records': false},
      {'versions': true, 'records': false},
    ]);
  });

  test('export falls back to GET when the version is not known', () async {
    server.exportTakesPost = false;
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
    final dump = await db.export(options: const ExportOptions(accesses: false));
    expect(dump, '-- export');
    expect(
        server.requests, containsAllInOrder(['POST /export', 'GET /export']));
  });
}
