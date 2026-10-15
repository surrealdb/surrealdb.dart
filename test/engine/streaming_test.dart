@TestOn('vm')
library;

import 'dart:async';

import 'package:surrealdb/src/engine/websocket_engine.dart';
import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  const frames = [
    {'stream': 'begin', 'version': 1, 'statements': 3},
    {
      'stream': 'rows',
      'index': 0,
      'values': [1, 2],
    },
    {
      'stream': 'rows',
      'index': 0,
      'values': [3],
    },
    {'stream': 'finished', 'index': 0, 'single': false, 'time': '1ms'},
    {'stream': 'value', 'index': 1, 'value': 'x'},
    {'stream': 'finished', 'index': 1, 'single': true, 'time': '1ms'},
    {
      'stream': 'finished',
      'index': 2,
      'single': false,
      'error': {'code': -32006, 'message': 'boom', 'kind': 'Thrown'},
    },
    {'stream': 'end', 'results': 3, 'time': '3ms'},
  ];

  Future<void> connect(String version) async {
    server.handler = (r) => switch (r.method) {
          'version' => FakeResult(version),
          'query_stream' => const FakeResults(frames),
          _ => FakeSurrealServer.defaultReply(r),
        };
    await db.connect(server.url);
  }

  setUp(() async {
    server = await FakeSurrealServer.start();
    db = Surreal();
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('turns stream replies into frames', () async {
    await connect('surrealdb-3.3.4');
    final received = await db.queryStream('q').toList();
    expect(server.methods.last, 'query_stream');
    expect(received, hasLength(6));
    expect(received[0],
        isA<QueryRows>().having((f) => f.values, 'values', [1, 2]));
    expect(
        received[1], isA<QueryRows>().having((f) => f.values, 'values', [3]));
    expect(
        received[2],
        isA<QueryStatementDone>()
            .having((f) => f.statement, 'statement', 0)
            .having((f) => f.ok, 'ok', isTrue));
    expect(received[3], isA<QueryValue>().having((f) => f.value, 'value', 'x'));
    expect(received[4],
        isA<QueryStatementDone>().having((f) => f.single, 'single', isTrue));
    expect(
        received[5],
        isA<QueryStatementDone>()
            .having((f) => f.error, 'error', isA<ThrownError>())
            .having((f) => f.error?.statementIndex, 'statementIndex', 2));
  });

  test('cancelling the stream cancels the query on the server', () async {
    await connect('surrealdb-3.3.4');
    server.handler = (r) => switch (r.method) {
          // Never sends the end, as a long query would not yet.
          'query_stream' => FakeResults(frames.sublist(0, 2)),
          'query_cancel' => _endStream(server, r),
          _ => FakeSurrealServer.defaultReply(r),
        };
    final first = await db.queryStream('SELECT * FROM big').first;
    expect(first, isA<QueryRows>());
    final requestId =
        server.requests.lastWhere((r) => r.method == 'query_stream').id;
    await eventually(() => server.methods.contains('query_cancel'));
    expect(server.requests.last.params, [requestId]);
  });

  test('a cancelled stream in a transaction ends before the commit', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await connect('surrealdb-3.3.4');
    var ended = false;
    bool? committedAfterEnd;
    server.handler = (r) {
      switch (r.method) {
        case 'begin':
          return FakeResult(txn);
        case 'query_stream':
          return FakeResults(frames.sublist(0, 2));
        case 'query_cancel':
          // The server ends the stream a little after it acknowledges.
          Timer(const Duration(milliseconds: 200), () {
            ended = true;
            server.push({
              'id': r.params.first,
              'result': {'stream': 'end', 'results': 0, 'time': '1ms'},
            });
          });
          return const FakeResult(null);
        case 'commit':
          committedAfterEnd = ended;
          return const FakeResult(null);
        default:
          return FakeSurrealServer.defaultReply(r);
      }
    };
    final transaction = await db.beginTransaction();
    await transaction.queryStream('SELECT * FROM big').first;
    await transaction.commit();
    expect(committedAfterEnd, isTrue);
  });

  test('commit waits for a stream still being read to end', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await connect('surrealdb-3.3.4');
    var ended = false;
    bool? committedAfterEnd;
    server.handler = (r) {
      switch (r.method) {
        case 'begin':
          return FakeResult(txn);
        case 'query_stream':
          Timer(const Duration(milliseconds: 200), () {
            ended = true;
            server.push({
              'id': r.id,
              'result': {'stream': 'end', 'results': 1, 'time': '1ms'},
            });
          });
          return FakeResults(frames.sublist(0, 2));
        case 'commit':
          committedAfterEnd = ended;
          return const FakeResult(null);
        default:
          return FakeSurrealServer.defaultReply(r);
      }
    };
    final transaction = await db.beginTransaction();
    final read = transaction.queryStream('SELECT * FROM big').toList();
    await eventually(() => server.methods.contains('query_stream'));
    await transaction.commit();
    expect(committedAfterEnd, isTrue);
    await read;
  });

  test('a stream that times out ends on the server before it fails', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await db.connect(server.url,
        options:
            const ConnectOptions(requestTimeout: Duration(milliseconds: 300)));
    var ended = false;
    bool? committedAfterEnd;
    server.handler = (r) {
      switch (r.method) {
        case 'begin':
          return FakeResult(txn);
        case 'query_stream':
          return const FakeSilence();
        case 'query_cancel':
          Timer(const Duration(milliseconds: 150), () {
            ended = true;
            server.push({
              'id': r.params.first,
              'result': {'stream': 'end', 'results': 0, 'time': '1ms'},
            });
          });
          return const FakeResult(null);
        case 'commit':
          committedAfterEnd = ended;
          return const FakeResult(null);
        default:
          return FakeSurrealServer.defaultReply(r);
      }
    };
    final transaction = await db.beginTransaction();
    await expectLater(transaction.queryStream('q').toList(),
        throwsA(isA<RequestTimeoutError>()));
    await transaction.commit();
    expect(committedAfterEnd, isTrue);
  });

  test('a refused cancel drops the socket, which stops the query', () async {
    await connect('surrealdb-3.3.4');
    server.handler = (r) => switch (r.method) {
          'query_stream' => FakeResults(frames.sublist(0, 2)),
          'query_cancel' => const FakeError('Method not allowed',
              code: -32602, extra: {'kind': 'NotAllowed'}),
          _ => FakeSurrealServer.defaultReply(r),
        };
    await db.queryStream('q').first;
    await eventually(() => server.accepted == 2);
  });

  test('a cancel that fails after the stream ended keeps the socket', () async {
    await connect('surrealdb-3.3.4');
    FakeRequest? stream;
    server.handler = (r) {
      switch (r.method) {
        case 'query_stream':
          stream = r;
          return FakeResults(frames.sublist(0, 2));
        case 'query_cancel':
          // The query finished just before the cancel reached the server.
          server.push({'id': stream!.id, 'result': frames.last});
          return const FakeError(
              'No streaming query with this request id is in progress',
              code: -32000);
        default:
          return FakeSurrealServer.defaultReply(r);
      }
    };
    await db.queryStream('q').first;
    await eventually(() => server.methods.contains('query_cancel'));
    expect((await db.query('RETURN 1')), isNotNull);
    expect(server.accepted, 1);
  });

  test('commit waits for a buffered transaction query too', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await connect('surrealdb-3.2.0');
    FakeRequest? held;
    server.handler = (r) {
      switch (r.method) {
        case 'begin':
          return FakeResult(txn);
        case 'query':
          held = r;
          return const FakeSilence();
        default:
          return FakeSurrealServer.defaultReply(r);
      }
    };
    final transaction = await db.beginTransaction();
    final read = transaction.queryStream('q').toList();
    await eventually(() => held != null);
    final committing = transaction.commit();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.methods, isNot(contains('commit')));

    held!.socket.add(const CborCodec().encode({
      'id': held!.id,
      'result': [
        {'status': 'OK', 'time': '1ms', 'result': 1},
      ],
    }));
    await read;
    await committing;
    expect(server.methods.last, 'commit');
  });

  for (final version in ['surrealdb-3.3.4', 'surrealdb-3.2.0']) {
    test('a commit straight after listening runs the query first ($version)',
        () async {
      final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
      await connect(version);
      server.handler = (r) => switch (r.method) {
            'begin' => FakeResult(txn),
            'query_stream' => const FakeResults(frames),
            'query' => const FakeResult([
                {'status': 'OK', 'time': '1ms', 'result': 1},
              ]),
            _ => FakeSurrealServer.defaultReply(r),
          };
      final transaction = await db.beginTransaction();
      final read = transaction.queryStream('q').toList();
      await transaction.commit();
      expect(await read, isNotEmpty);
      expect(server.methods.last, 'commit');
    });
  }

  test('a stream first listened to after commit fails', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await connect('surrealdb-3.3.4');
    server.handler = (r) => r.method == 'begin'
        ? FakeResult(txn)
        : FakeSurrealServer.defaultReply(r);
    final transaction = await db.beginTransaction();
    final stream = transaction.queryStream('q');
    await transaction.commit();
    await expectLater(stream.toList(), throwsA(isA<TransactionClosedError>()));
    expect(server.methods, isNot(contains('query_stream')));
  });

  test('cancelling a timed out stream waits for it to stop', () async {
    final engine = WebSocketEngine(const CborCodec(),
        requestTimeout: const Duration(milliseconds: 300));
    addTearDown(engine.close);
    await engine.open(Uri.parse(server.url));
    var cancelled = false;
    var ended = false;
    server.handler = (r) {
      switch (r.method) {
        case 'query_stream':
          return const FakeSilence();
        case 'query_cancel':
          cancelled = true;
          Timer(const Duration(milliseconds: 200), () {
            ended = true;
            server.push({
              'id': r.params.first,
              'result': {'stream': 'end', 'results': 0, 'time': '1ms'},
            });
          });
          return const FakeResult(null);
        default:
          return FakeSurrealServer.defaultReply(r);
      }
    };
    final subscription = engine
        .rpcStream('query_stream', ['q', <String, Object?>{}]).listen((_) {},
            onError: (_) {});
    await eventually(() => cancelled);
    await subscription.cancel();
    expect(ended, isTrue);
  });

  test('a stream whose request cannot be sent fails', () async {
    await connect('surrealdb-3.3.4');
    await expectLater(
        db
            .queryStream('q', bindings: {'x': Object()})
            .toList()
            .timeout(const Duration(seconds: 2)),
        throwsA(isNot(isA<TimeoutException>())));
    expect(server.methods, isNot(contains('query_stream')));
    expect((await db.query('RETURN 1')), isNotNull);
  });

  test('streaming is tried again after a reconnect', () async {
    await db.connect(server.url,
        options: const ConnectOptions(
          versionCheck: false,
          reconnect: ReconnectOptions(
            retryDelay: Duration(milliseconds: 10),
            retryDelayMax: Duration(milliseconds: 10),
          ),
        ));
    server.handler = (r) => switch (r.method) {
          'query_stream' => const FakeError('Method not found', code: -32601),
          'query' => const FakeResult([
              {'status': 'OK', 'time': '1ms', 'result': 1},
            ]),
          _ => FakeSurrealServer.defaultReply(r),
        };
    await db.queryStream('q').drain<void>();

    server.handler = (r) => switch (r.method) {
          'query_stream' => const FakeResults(frames),
          _ => FakeSurrealServer.defaultReply(r),
        };
    await server.dropAll();
    await eventually(
        () => db.status == ConnectionStatus.connected && server.accepted == 2);
    server.requests.clear();
    await db.queryStream('q').drain<void>();
    expect(server.methods, contains('query_stream'));
  });

  test('a stream with no first reply times out', () async {
    await db.connect(server.url,
        options: const ConnectOptions(
            versionCheck: false, requestTimeout: Duration(milliseconds: 300)));
    server.handler = (r) => switch (r.method) {
          'query_stream' => const FakeSilence(),
          'query_cancel' => _endStream(server, r),
          _ => FakeSurrealServer.defaultReply(r),
        };
    await expectLater(
        db.queryStream('q').toList(), throwsA(isA<RequestTimeoutError>()));
    await eventually(() => server.methods.contains('query_cancel'));
  });

  test('falls back to a buffered query before 3.3', () async {
    await connect('surrealdb-3.2.0');
    server.handler = (r) => r.method == 'query'
        ? const FakeResult([
            {
              'status': 'OK',
              'time': '1ms',
              'result': [1, 2]
            },
            {'status': 'OK', 'time': '1ms', 'result': 'x'},
            {
              'status': 'ERR',
              'time': '1ms',
              'result': 'boom',
              'kind': 'Thrown'
            },
          ])
        : FakeSurrealServer.defaultReply(r);
    final received = await db.queryStream('q').toList();
    expect(server.methods, isNot(contains('query_stream')));
    expect(received.map((f) => f.runtimeType), [
      QueryRows,
      QueryStatementDone,
      QueryValue,
      QueryStatementDone,
      QueryStatementDone,
    ]);
    expect((received.last as QueryStatementDone).error, isA<ThrownError>());
  });

  test('falls back, and remembers, when the server refuses to stream',
      () async {
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
    server.handler = (r) => switch (r.method) {
          'query_stream' => const FakeError('Method not found', code: -32601),
          'query' => const FakeResult([
              {'status': 'OK', 'time': '1ms', 'result': 1},
            ]),
          _ => FakeSurrealServer.defaultReply(r),
        };
    expect(await db.queryStream('q').toList(), hasLength(2));
    expect(await db.queryStream('q').toList(), hasLength(2));
    expect(server.methods.where((m) => m == 'query_stream'), hasLength(1));
    expect(server.methods.where((m) => m == 'query'), hasLength(2));
  });

  test('falls back when the capabilities deny streaming', () async {
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
    server.handler = (r) => switch (r.method) {
          'query_stream' =>
            const FakeError('Method not allowed', code: -32602, extra: {
              'kind': 'NotAllowed',
              'details': {
                'kind': 'Method',
                'details': {'name': 'query_stream'},
              },
            }),
          'query' => const FakeResult([
              {'status': 'OK', 'time': '1ms', 'result': 1},
            ]),
          _ => FakeSurrealServer.defaultReply(r),
        };
    expect(await db.queryStream('q').toList(), hasLength(2));
    expect(server.methods.where((m) => m == 'query_stream'), hasLength(1));
  });

  test('a failed query fails the stream', () async {
    await connect('surrealdb-3.3.4');
    server.handler = (r) => r.method == 'query_stream'
        ? const FakeError('Parse error', extra: {'kind': 'Validation'})
        : FakeSurrealServer.defaultReply(r);
    await expectLater(
        db.queryStream('nonsense').toList(), throwsA(isA<ValidationError>()));
  });

  test('streams inside a transaction carry its id', () async {
    final txn = Uuid('0192e3c4-0000-7000-8000-000000000001');
    await connect('surrealdb-3.3.4');
    server.handler = (r) => switch (r.method) {
          'begin' => FakeResult(txn),
          'query_stream' => const FakeResults(frames),
          _ => FakeSurrealServer.defaultReply(r),
        };
    final transaction = await db.beginTransaction();
    await transaction.queryStream('q').drain<void>();
    expect(server.requests.last.raw['txn'], txn);
  });
}

/// Acknowledges a `query_cancel` and ends the stream it names, as the server
/// does.
FakeReply _endStream(FakeSurrealServer server, FakeRequest request) {
  server.push({
    'id': request.params.first,
    'result': {'stream': 'end', 'results': 0, 'time': '1ms'},
  });
  return const FakeResult(null);
}
