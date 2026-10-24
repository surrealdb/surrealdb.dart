@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

const _noGql = 'the server has not enabled the experimental gql capability';

/// Whether the server runs GQL. 3.2 needs `--allow-experimental gql`, which
/// the CI server does not set, so the GQL tests skip there.
Future<bool> gqlEnabled(Surreal db) async {
  try {
    await db.gql('MATCH (n:gql_probe) RETURN n');
  } on NotAllowedError catch (e) {
    return !e.message.contains('Experimental capability');
  } on Object {
    // Any other failure means the statement ran.
  }
  return true;
}

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
        DEFINE API OVERWRITE "/body-type" FOR post THEN {
          RETURN { status: 200, body: type::of($request.body) };
        };
        DEFINE API OVERWRITE "/reply" FOR get THEN {
          RETURN IF $request.query.empty = "none" { { status: 200 } }
            ELSE { { status: 200, body: NULL } };
        };
        DEFINE API OVERWRITE "/trace" FOR trace THEN {
          RETURN { status: 200, body: $request.body };
        };
      ''');
      await admin.close();
    });

    tearDownAll(() async {
      final admin = await connectRoot(wsUrl);
      await admin.query('REMOVE TABLE IF EXISTS gperson; '
          'REMOVE TABLE IF EXISTS knows; REMOVE CONFIG IF EXISTS GRAPHQL; '
          'REMOVE API IF EXISTS "/greet/:name"; REMOVE API IF EXISTS "/echo"; '
          'REMOVE API IF EXISTS "/body-type"; REMOVE API IF EXISTS "/reply"; '
          'REMOVE API IF EXISTS "/trace";');
      await admin.close();
    });

    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async => db = await connectRoot(url));
        tearDown(() async => db.close());

        test('gql runs an ISO GQL graph query with bindings', () async {
          if (!await gqlEnabled(db)) return markTestSkipped(_noGql);
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
          if (!await gqlEnabled(db)) return markTestSkipped(_noGql);
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

        test('api tells an explicit null body from no body', () async {
          expect((await db.api.post('/body-type', body: null)).body, 'null');
          expect((await db.api.post('/body-type')).body, 'none');
        });

        test('api tells a response with no body from a null body', () async {
          final empty = await db.api.get('/reply', query: {'empty': 'none'});
          final nulled = await db.api.get('/reply', query: {'empty': 'null'});
          expect(empty.body, none);
          expect(nulled.body, isNull);
        });

        test('api sends a body with trace', () async {
          final response = await db.api.trace('/trace', body: {'n': 1});
          expect(response.body, {'n': 1});
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
