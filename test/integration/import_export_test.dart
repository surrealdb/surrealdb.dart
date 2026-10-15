@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('import and export', () {
    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async {
          db = await connectRoot(url);
          await db.query('REMOVE TABLE IF EXISTS imported; '
              'REMOVE TABLE IF EXISTS exported;');
        });
        tearDown(() async {
          await db.query('REMOVE TABLE IF EXISTS imported; '
              'REMOVE TABLE IF EXISTS exported;');
          await db.close();
        });

        test('a clean import succeeds', () async {
          await db
              .import('OPTION IMPORT; CREATE imported:1; CREATE imported:2;');
          final [rows] = await db.query('SELECT * FROM imported');
          expect(rows, hasLength(2));
        });

        test('failed statements are reported and the rest applied', () async {
          await expectLater(
            db.import('OPTION IMPORT; CREATE imported:1; THROW "bad"; '
                'CREATE imported:1; CREATE imported:2;'),
            throwsA(isA<ImportError>()
                .having((e) => e.failed, 'failed', 2)
                .having((e) => e.failures[0], 'first', isA<ThrownError>())
                .having(
                    (e) => e.failures[1], 'second', isA<AlreadyExistsError>())),
          );
          final [rows] = await db.query('SELECT * FROM imported');
          expect(rows, hasLength(2));
        });

        test('a document the server rejects says why', () async {
          await expectLater(
            db.import('CREATE imported:1;'),
            throwsA(isA<HttpConnectionError>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having(
                    (e) => e.message, 'message', contains('OPTION IMPORT'))),
          );
        });

        test('export options choose what is exported', () async {
          await db.query('CREATE exported:1; CREATE imported:1;');
          final dump = await db.export(
            options: ExportOptions(
              tables: ExportTables.only(['exported']),
              users: false,
              accesses: false,
            ),
          );
          expect(dump, contains('exported:1'));
          expect(dump, isNot(contains('imported')));

          final schemaOnly =
              await db.export(options: const ExportOptions(records: false));
          expect(schemaOnly, contains('DEFINE TABLE exported'));
          expect(schemaOnly, isNot(contains('exported:1')));
        });

        test('an export imports back', () async {
          await db.query('CREATE exported:1 SET n = 1');
          // Access methods are left out: the server redacts their keys in an
          // export, so they cannot be imported back.
          final dump = await db.export(
              options: ExportOptions(
                  tables: ExportTables.only(['exported']), accesses: false));
          await db.query('REMOVE TABLE exported');
          await db.import(dump);
          final [rows] = await db.query('SELECT * FROM exported');
          expect(rows, [
            {'id': const RecordId('exported', 1), 'n': 1},
          ]);
        });
      });
    }
  }, skip: skipIntegration);
}
