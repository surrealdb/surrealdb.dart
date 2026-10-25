@TestOn('vm')
library;

import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  const options = ConnectOptions(versionCheck: false);

  group('over WebSocket', () {
    late FakeSurrealServer server;
    late Surreal db;

    setUp(() async {
      server = await FakeSurrealServer.start();
      db = Surreal();
    });

    tearDown(() async {
      await db.close();
      await server.close();
    });

    test('offers cbor.2, then cbor', () async {
      await db.connect(server.url, options: options);
      expect(server.offered, ['cbor.2', 'cbor']);
      expect((db.codec! as CborCodec).sizedNumbers, isTrue);
    });

    test('speaks cbor to a server that picks it', () async {
      server.selectProtocol = (offered) => 'cbor';
      await db.connect(server.url, options: options);
      expect((db.codec! as CborCodec).sizedNumbers, isFalse);
    });

    test('offers a codec of the caller\'s own as it is', () async {
      await db.connect(server.url,
          options: ConnectOptions(versionCheck: false, codec: _OwnCodec()));
      expect(server.offered, ['cbor']);
      expect(db.codec, isA<_OwnCodec>());
    });
  });

  group('over HTTP', () {
    late HttpServer server;
    late Surreal db;
    final requests = <(String?, String?)>[];
    var replyType = 'application/cbor';

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add((
          request.headers.value('content-type'),
          request.headers.value('accept'),
        ));
        final call = const CborCodec(sizedNumbers: true).decode(
            await request.fold<List<int>>([], (a, b) => a..addAll(b))) as Map;
        request.response
          ..headers.set('content-type', replyType)
          ..add(const CborCodec(sizedNumbers: true).encode({
            'id': call['id'],
            'result': [
              {'status': 'OK', 'time': '1ms', 'result': SizedInt.u8(5)},
            ],
          }));
        await request.response.close();
      });
      db = Surreal();
      await db.connect('http://127.0.0.1:${server.port}/rpc', options: options);
    });

    tearDown(() async {
      await db.close();
      await server.close(force: true);
    });

    test('asks for cbor.2, and sends it once the server answers in it',
        () async {
      replyType = 'application/cbor; v=2';
      expect(await db.query('RETURN 5u8'), [SizedInt.u8(5)]);
      await db.query('RETURN 1');
      expect(requests, [
        ('application/cbor', 'application/cbor; v=2'),
        ('application/cbor; v=2', 'application/cbor; v=2'),
      ]);
      expect((db.codec! as CborCodec).sizedNumbers, isTrue);
    });

    test('keeps to cbor with a server that answers in it', () async {
      replyType = 'application/cbor';
      await expectLater(db.query('RETURN 1'), throwsFormatException);
      await db.query('RETURN 1').catchError((_) => <Object?>[]);
      expect(requests.map((r) => r.$1), everyElement('application/cbor'));
      expect((db.codec! as CborCodec).sizedNumbers, isFalse);
    });
  });
}

class _OwnCodec extends CborCodec {}
