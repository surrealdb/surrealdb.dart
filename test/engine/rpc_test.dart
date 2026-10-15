import 'dart:convert' show jsonEncode, utf8;
import 'dart:typed_data';

import 'package:surrealdb/src/engine/rpc.dart';
import 'package:surrealdb/src/json/codec.dart';
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

  test('reads the record id of a diff notification from record', () {
    final bytes = codec.encode({
      'result': {
        'id': Uuid('01234567-89ab-4def-8123-456789abcdef'),
        'action': 'UPDATE',
        'record': const RecordId('person', 'tobie'),
        'result': [
          {'op': 'replace', 'path': '/age', 'value': 33},
        ],
      },
    });
    final incoming = protocol.decodeIncoming(bytes) as RpcNotification;
    expect(incoming.message.recordId, const RecordId('person', 'tobie'));
    expect(incoming.message.value, isA<List<Object?>>());
  });

  test('reads a JSON diff notification record id from its string', () {
    final json = RpcProtocol(const JsonCodec());
    final bytes = utf8.encode(jsonEncode({
      'result': {
        'id': '01234567-89ab-4def-8123-456789abcdef',
        'action': 'UPDATE',
        'record': 'person:diff',
        'result': [
          {'op': 'replace', 'path': '/age', 'value': 33},
        ],
      },
    }));
    final incoming = json.decodeIncoming(bytes) as RpcNotification;
    expect(incoming.message.recordId, const RecordId('person', 'diff'));
  });

  test('parses the string forms of a record id', () {
    expect(parseRecordId('person:tobie'), const RecordId('person', 'tobie'));
    expect(parseRecordId('person:1'), const RecordId('person', 1));
    expect(parseRecordId('person:-5'), const RecordId('person', -5));
    expect(parseRecordId('person:`a b`'), const RecordId('person', 'a b'));
    expect(parseRecordId(r'person:`a\`b`'), const RecordId('person', 'a`b'));
    expect(parseRecordId('person:⟨a b⟩'), const RecordId('person', 'a b'));
    expect(parseRecordId('`my table`:x'), const RecordId('my table', 'x'));
    expect(parseRecordId('person:`12345678901234567890`'),
        const RecordId('person', '12345678901234567890'));
    expect(parseRecordId("person:u'018f1c8e-7d2a-7cc0-9a1b-1234567890ab'"),
        RecordId('person', Uuid('018f1c8e-7d2a-7cc0-9a1b-1234567890ab')));
    expect(
        parseRecordId("person:[1, 'a']"), const RecordId('person', [1, 'a']));
    expect(parseRecordId('person:[]'), const RecordId('person', []));
    expect(parseRecordId('x:{ a: 1, "b c": \'d\', nested: { x: [1] } }')?.id, {
      'a': 1,
      'b c': 'd',
      'nested': {
        'x': [1],
      },
    });
    final mixed = parseRecordId(
        "person:[1.5f, 'a\\\\b', \"x'y\", `a b`:1, NULL, false, -3, 1.5dec, "
        "1h30m, d'2024-01-01T00:00:00Z', u'018f1c8e-7d2a-7cc0-9a1b-1234567890ab']");
    expect(mixed?.id, [
      1.5,
      r'a\b',
      "x'y",
      const RecordId('a b', 1),
      null,
      false,
      -3,
      const Decimal('1.5'),
      SurrealDuration.parse('1h30m'),
      SurrealDateTime.parse('2024-01-01T00:00:00Z'),
      Uuid('018f1c8e-7d2a-7cc0-9a1b-1234567890ab'),
    ]);
    // Strings are written with escapes, as the server writes them.
    expect(
        parseRecordId(
                r'''item:["line\nfeed\ttab\\back'q\"dq", 'caf\u{e9}\u00e9']''')
            ?.id,
        ['line\nfeed\ttab\\back\'q"dq', 'café\u00e9']);
    // Datetimes keep their nanoseconds.
    expect(parseRecordId("event:[d'2026-01-01T00:00:00.123456789Z']")?.id,
        [SurrealDateTime(1767225600, 123456789)]);
    // Past 53 bits an integer stays exact, as a BigInt on the web.
    expect(parseRecordId('person:9007199254740993')?.id.toString(),
        '9007199254740993');
    expect(parseRecordId('person:[9007199254740993]')?.id.toString(),
        '[9007199254740993]');
    // Bytes, as the server writes them.
    expect(parseRecordId('item:[b"7879", b""]')?.id, [
      Uint8List.fromList([0x78, 0x79]),
      Uint8List(0),
    ]);
    expect(parseRecordId('person:[1, '), isNull);
    expect(parseRecordId('person'), isNull);
  });
}
