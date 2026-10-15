import 'package:surrealdb/src/engine/rpc.dart';
import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  final protocol = RpcProtocol(const CborCodec());
  const codec = CborCodec();

  ServerError decode(Map<String, Object?> error) =>
      protocol.decodeResponse(codec.encode({'id': '1', 'error': error})).error!
          as ServerError;

  test('reads the kind and nested details of an RPC error', () {
    final error = decode({
      'code': -32002,
      'message': 'Token expired',
      'kind': 'NotAllowed',
      'details': {
        'kind': 'Auth',
        'details': {'kind': 'TokenExpired'},
      },
      'cause': null,
    });
    expect(error, isA<NotAllowedError>());
    expect(error.kind, ErrorKind.notAllowed);
    expect(error.code, -32002);
    expect(error.message, 'Token expired');
    expect(error.details!.kind, 'Auth');
    expect(error.details!.inner!.kind, 'TokenExpired');
    expect((error as NotAllowedError).isTokenExpired, isTrue);
    expect(error.isInvalidAuth, isFalse);
    expect(error.cause, isNull);
  });

  test('reads detail fields', () {
    final error = decode({
      'code': -32000,
      'message': "The table 'person' does not exist",
      'kind': 'NotFound',
      'details': {
        'kind': 'Table',
        'details': {'name': 'person'},
      },
    }) as NotFoundError;
    expect(error.tableName, 'person');
    expect(error.recordId, isNull);
  });

  test('reads a cause', () {
    final error = decode({
      'code': -32000,
      'message': 'outer',
      'kind': 'Internal',
      'cause': {'code': -32006, 'message': 'inner', 'kind': 'Thrown'},
    });
    expect(error.cause, isA<ThrownError>());
    expect(error.cause!.message, 'inner');
  });

  test('maps every kind to its class', () {
    final classes = {
      'Validation': isA<ValidationError>(),
      'Configuration': isA<ConfigurationError>(),
      'Query': isA<QueryError>(),
      'Serialization': isA<SerializationError>(),
      'NotAllowed': isA<NotAllowedError>(),
      'NotFound': isA<NotFoundError>(),
      'AlreadyExists': isA<AlreadyExistsError>(),
      'Connection': isA<ServerConnectionError>(),
      'Thrown': isA<ThrownError>(),
      'Internal': isA<InternalError>(),
      'Context': isA<ContextError>(),
    };
    for (final MapEntry(key: kind, value: matcher) in classes.entries) {
      final error = decode({'code': -32000, 'message': 'x', 'kind': kind});
      expect(error, matcher, reason: kind);
      expect(error.kind.wireName, kind);
      expect(error.rawKind, kind);
    }
  });

  test('an unknown kind is internal and keeps its name', () {
    final error = decode({'code': -32000, 'message': 'x', 'kind': 'Brand'});
    expect(error, isA<InternalError>());
    expect(error.rawKind, 'Brand');
  });

  test('falls back to the code when there is no kind', () {
    expect(decode({'code': -32601, 'message': 'x'}), isA<NotFoundError>());
    expect(decode({'code': -32002, 'message': 'x'}), isA<NotAllowedError>());
    expect(decode({'code': -32700, 'message': 'x'}), isA<ValidationError>());
    expect(decode({'code': -32006, 'message': 'x'}), isA<ThrownError>());
    expect(decode({'code': -32009, 'message': 'x'}), isA<QueryError>());
    expect(decode({'code': -1, 'message': 'x'}), isA<InternalError>());
  });

  test('server errors are still response errors', () {
    expect(decode({'code': -32000, 'message': 'x', 'kind': 'Thrown'}),
        isA<ResponseError>());
  });

  test('reads a failed query statement', () {
    final error = ServerError.fromStatement({
      'status': 'ERR',
      'result': "The namespace 'x' does not exist",
      'kind': 'NotFound',
      'details': {
        'kind': 'Namespace',
        'details': {'name': 'x'},
      },
    }, index: 2);
    expect(error, isA<NotFoundError>());
    expect((error as NotFoundError).namespaceName, 'x');
    expect(error.statementIndex, 2);
    expect(error.code, 0);
  });

  test('a statement error without a kind is internal, not thrown', () {
    final error = ServerError.fromStatement({
      'status': 'ERR',
      'result': 'Database record `person:1` already exists',
    });
    expect(error, isA<InternalError>());
    expect(error, isNot(isA<ThrownError>()));
  });

  test('the helpers read the legacy codes when there is no detail', () {
    final timedOut = decode({'code': -32004, 'message': 'x'});
    expect(timedOut, isA<QueryError>());
    expect((timedOut as QueryError).isTimedOut, isTrue);
    expect(timedOut.isCancelled, isFalse);
    expect(timedOut.timeout, isNull);
    expect((decode({'code': -32005, 'message': 'x'}) as QueryError).isCancelled,
        isTrue);
    expect(
        (decode({'code': -32009, 'message': 'x'}) as QueryError)
            .isTransactionConflict,
        isTrue);
    expect(
        (decode({'code': -32003, 'message': 'x'}) as QueryError).isNotExecuted,
        isTrue);
    expect(
        (decode({'code': -32700, 'message': 'x'}) as ValidationError)
            .isParseError,
        isTrue);
    expect(
        (decode({'code': -32604, 'message': 'x'}) as ConfigurationError)
            .isLiveQueryNotSupported,
        isTrue);
    expect(
        (decode({'code': -32008, 'message': 'x'}) as SerializationError)
            .isDeserialization,
        isTrue);
    final auth = decode({'code': -32002, 'message': 'x'}) as NotAllowedError;
    expect(auth.isInvalidAuth, isTrue);
    expect(auth.isAuthError, isTrue);
    // A structured detail still decides.
    final structured = decode({
      'code': -32004,
      'message': 'x',
      'kind': 'Query',
      'details': {'kind': 'Cancelled'},
    }) as QueryError;
    expect(structured.isTimedOut, isFalse);
    expect(structured.isCancelled, isTrue);
  });
}
