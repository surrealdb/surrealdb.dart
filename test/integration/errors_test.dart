@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('structured errors', () {
    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async => db = await connectRoot(url));
        tearDown(() async => db.close());

        test('a failed signin is a NotAllowedError', () async {
          await expectLater(
            db.signin(const RootAuth(username: 'root', password: 'wrong')),
            throwsA(isA<NotAllowedError>()
                .having((e) => e.isInvalidAuth, 'isInvalidAuth', isTrue)
                .having((e) => e.code, 'code', -32002)),
          );
        });

        test('a THROW statement is a ThrownError with its index', () async {
          await expectLater(
            db.query('RETURN 1; THROW "boom";'),
            throwsA(isA<ThrownError>()
                .having((e) => e.statementIndex, 'statementIndex', 1)
                .having((e) => e.message, 'message', contains('boom'))),
          );
        });

        test('a missing table in strict mode is a NotFoundError', () async {
          await db.query('DEFINE DATABASE IF NOT EXISTS strictdb STRICT');
          await db.use(database: 'strictdb');
          await expectLater(
            db.query('SELECT * FROM missing'),
            throwsA(isA<NotFoundError>()
                .having((e) => e.tableName, 'tableName', 'missing')),
          );
        });

        test('a duplicate record is an AlreadyExistsError', () async {
          await db.query(
              'DEFINE TABLE IF NOT EXISTS dup; DELETE dup:1; CREATE dup:1;');
          await expectLater(
            db.query('CREATE dup:1'),
            throwsA(isA<AlreadyExistsError>()),
          );
          await db.query('DELETE dup:1');
        });
      });
    }
  }, skip: skipIntegration);
}
