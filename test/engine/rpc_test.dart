import 'package:surrealdb/src/engine/rpc.dart';
import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  final protocol = RpcProtocol(const CborCodec());
  const codec = CborCodec();

  test('encodes a request envelope', () {
    final bytes =
        protocol.encodeRequest('1', 'select', [const Table('person')]);
    final decoded = codec.decode(bytes) as Map;
    expect(decoded['id'], '1');
    expect(decoded['method'], 'select');
    expect(decoded['params'], [const Table('person')]);
  });

  test('generates increasing ids', () {
    final first = protocol.nextId();
    final second = protocol.nextId();
    expect(int.parse(second), greaterThan(int.parse(first)));
  });

  test('decodes a successful response', () {
    final bytes = codec.encode({'id': '7', 'result': 42});
    final response = protocol.decodeResponse(bytes);
    expect(response.id, '7');
    expect(response.result, 42);
    expect(response.error, isNull);
  });

  test('decodes an error response', () {
    final bytes = codec.encode({
      'id': '7',
      'error': {'code': -32602, 'message': 'Invalid params'},
    });
    final response = protocol.decodeResponse(bytes);
    expect(response.error, isA<ResponseError>());
    expect(response.error!.code, -32602);
  });

  test('classifies a live notification', () {
    final bytes = codec.encode({
      'result': {
        'id': Uuid('8c6c5b1e-3a3a-4b3a-9b3a-1a2b3c4d5e6f'),
        'action': 'CREATE',
        'result': {'id': const RecordId('person', 'tobie'), 'name': 'Tobie'},
      },
    });
    final incoming = protocol.decodeIncoming(bytes);
    expect(incoming, isA<RpcNotification>());
    final message = (incoming! as RpcNotification).message;
    expect(message.action, LiveAction.create);
    expect(message.recordId, const RecordId('person', 'tobie'));
  });

  test('classifies a response over the streaming decoder', () {
    final bytes = codec.encode({'id': '3', 'result': true});
    final incoming = protocol.decodeIncoming(bytes);
    expect(incoming, isA<RpcResponse>());
    expect((incoming! as RpcResponse).result, true);
  });
}
