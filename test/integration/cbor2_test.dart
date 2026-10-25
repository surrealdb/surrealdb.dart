@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('cbor.2', () {
    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async => db = await connectRoot(url));
        tearDown(() async => db.close());

        bool negotiated() => (db.codec! as CborCodec).sizedNumbers;

        test('is spoken with a 4.0 server, and cbor with an older one',
            () async {
          expect(negotiated(), await serverAtLeast(4, 0));
        });

        test('sized numbers keep their kind both ways', () async {
          if (!negotiated()) return markTestSkipped('needs cbor.2');
          final [u8, f32, i16, u64] = await db.query(
            r'RETURN 5u8; RETURN 1.5f32; RETURN type::of($x); RETURN $big',
            bindings: {
              'x': SizedInt.i16(-3),
              'big': SizedInt(SizedKind.u64, (BigInt.one << 64) - BigInt.one),
            },
          );
          expect(u8, SizedInt.u8(5));
          expect(f32, SizedFloat.f32(1.5));
          expect(i16, 'i16');
          expect(u64, SizedInt(SizedKind.u64, (BigInt.one << 64) - BigInt.one));
        });

        test('a sized record id key is a plain integer', () async {
          if (!negotiated()) return markTestSkipped('needs cbor.2');
          final [id] = await db.query(r'RETURN type::record("t", $key)',
              bindings: {'key': SizedInt.u8(5)});
          expect(id, const RecordId('t', 5));
        });

        test('a sized number is widened over plain cbor', () async {
          if (negotiated()) return markTestSkipped('needs plain cbor');
          final [type, value] = await db.query(
            r'RETURN type::of($x); RETURN $x',
            bindings: {'x': SizedInt.u8(5)},
          );
          expect(type, 'int');
          expect(value, 5);
        });
      });
    }
  }, skip: skipIntegration);
}
