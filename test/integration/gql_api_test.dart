@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('gql, graphql and api', () {
    setUpAll(() async {
      final admin = await connectRoot(wsUrl);
      await admin.query(r'''
        DEFINE CONFIG OVERWRITE GRAPHQL AUTO;
        DEFINE TABLE OVERWRITE gperson SCHEMAFULL;
        DEFINE FIELD OVERWRITE name ON gperson TYPE string;
        DEFINE TABLE OVERWRITE knows TYPE RELATION;
        CREATE gperson:a SET name = "Ann";
        CREATE gperson:b SET name = "Bob";
        RELATE gperson:a->knows->gperson:b;
        DEFINE API OVERWRITE "/greet/:name" FOR get THEN {
          RETURN {
            status: 200,
            headers: { "x-greeting": "hi" },
            body: {
              hello: $request.params.name,
              query: $request.query,
              tenant: $request.headers["x-tenant"],
            },
          };
        };
        DEFINE API OVERWRITE "/echo" FOR post THEN {
          RETURN { status: 201, body: $request.body };
        };
      ''');
      await admin.close();
    });

    tearDownAll(() async {
      final admin = await connectRoot(wsUrl);
      await admin.query('REMOVE TABLE IF EXISTS gperson; '
          'REMOVE TABLE IF EXISTS knows; REMOVE CONFIG IF EXISTS GRAPHQL; '
          'REMOVE API IF EXISTS "/greet/:name"; REMOVE API IF EXISTS "/echo";');
      await admin.close();
    });

    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async => db = await connectRoot(url));
        tearDown(() async => db.close());

        test('gql runs an ISO GQL graph query with bindings', () async {
          final [rows] = await db.gql(
            r'MATCH (p:gperson)-[:knows]->(f:gperson) WHERE p.name = $n '
            'RETURN f.name',
            bindings: {'n': 'Ann'},
          );
          expect(rows, [
            {'f.name': 'Bob'},
          ]);
        });

        test('gql statement errors are thrown', () async {
          await expectLater(
            db.gql('MATCH (p:nosuchlabel) RETURN p'),
            throwsA(isA<NotFoundError>()),
          );
        });

        test('graphql runs a request with variables', () async {
          final response = await db.graphql(
            r'query Q($id: ID!) { gperson(id: $id) { name } }',
            variables: {'id': 'a'},
            operationName: 'Q',
          );
          expect(response['data'], {
            'gperson': {'name': 'Ann'},
          });
        });

        test('api calls a defined API', () async {
          final response = await db.api
              .header('x-tenant', 'acme')
              .get('/greet/tobie', query: {'full': 'yes'});
          expect(response.status, 200);
          expect(response.ok, isTrue);
          expect(response.headers['x-greeting'], 'hi');
          expect(response.value(), {
            'hello': 'tobie',
            'query': {'full': 'yes'},
            'tenant': 'acme',
          });
        });

        test('api sends a body', () async {
          final response =
              await db.api.post('/echo', body: {'item': 'book', 'n': 2});
          expect(response.status, 201);
          expect(response.body, {'item': 'book', 'n': 2});
        });

        test('an unsuccessful api call throws from value()', () async {
          final response = await db.api.get('/missing');
          expect(response.status, 404);
          expect(response.ok, isFalse);
          expect(
              response.value,
              throwsA(isA<UnsuccessfulApiError>()
                  .having((e) => e.status, 'status', 404)));
        });
      });
    }
  }, skip: skipIntegration);
}
