@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  late FakeSurrealServer server;
  late Surreal db;

  setUp(() async {
    server = await FakeSurrealServer.start();
    db = Surreal();
    await db.connect(server.url,
        options: const ConnectOptions(versionCheck: false));
  });

  tearDown(() async {
    await db.close();
    await server.close();
  });

  test('a string is a table, even when it looks like a record id', () async {
    await db.select('person:1');
    expect(server.requests.last.params.first, const Table('person:1'));
  });

  test('a StringRecordId is sent for the server to parse', () async {
    await db.select(const StringRecordId('person:1'));
    // The wire carries tag 8 over the text `person:1`, which the server
    // parses. The codec reads that text form back as the record id it names,
    // so what the fake server decodes is a RecordId and not a Table -- the
    // distinction that matters here. The text form itself is pinned by
    // `a StringRecordId goes on the wire as text` in test/cbor/codec_test.dart.
    expect(server.requests.last.params.first, const RecordId('person', 1));
  });
}
