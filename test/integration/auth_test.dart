@TestOn('vm')
library;

import 'dart:math';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('refresh tokens', () {
    setUpAll(() async {
      final admin = await connectRoot(wsUrl);
      await admin.query(r'''
        DEFINE ACCESS OVERWRITE refreshing ON DATABASE TYPE RECORD
          SIGNUP (CREATE account SET email = $email,
                  pass = crypto::argon2::generate($pass))
          SIGNIN (SELECT * FROM account WHERE email = $email
                  AND crypto::argon2::compare(pass, $pass))
          WITH REFRESH
          DURATION FOR TOKEN 3s, FOR SESSION 1h;
      ''');
      await admin.close();
    });

    AccessRecordAuth newAccount() => AccessRecordAuth(
          namespace: 'test',
          database: 'test',
          access: 'refreshing',
          variables: {
            'email': '${Random().nextInt(1 << 32)}@example.com',
            'pass': 'secret',
          },
        );

    for (final MapEntry(key: engine, value: url) in engineUrls.entries) {
      group('over $engine', () {
        late Surreal db;

        setUp(() async {
          db = Surreal();
          await db.connect(url,
              options: const ConnectOptions(
                  namespace: 'test', database: 'test', renewTokens: false));
        });
        tearDown(() async => db.close());

        test('signup returns a refresh token', () async {
          final tokens = await db.signup(newAccount());
          expect(tokens.refresh, startsWith('surreal-refresh-'));
          expect(db.tokens, tokens);
        });

        test('refresh issues new tokens and spends the old one', () async {
          final first = await db.signup(newAccount());
          final second = await db.refresh();
          expect(second.access, isNot(first.access));
          expect(second.refresh, isNot(first.refresh));
          expect(db.tokens, second);
          expect((await db.query(r'RETURN $auth.email')).single, isNotNull);

          await expectLater(db.refresh(first), throwsA(isA<NotAllowedError>()));
        });

        test('a revoked refresh token cannot be used', () async {
          final tokens = await db.signup(newAccount());
          await db.revoke();
          expect(db.tokens?.refresh, isNull);
          await expectLater(
              db.refresh(tokens), throwsA(isA<NotAllowedError>()));
        });

        test('authenticate with an expired token uses the refresh token',
            () async {
          final tokens = await db.signup(newAccount());
          await Future<void>.delayed(const Duration(milliseconds: 3500));
          final other = Surreal();
          addTearDown(other.close);
          await other.connect(url,
              options: const ConnectOptions(
                  namespace: 'test', database: 'test', renewTokens: false));
          await other.authenticate(tokens.access, refreshToken: tokens.refresh);
          expect(other.tokens?.access, isNot(tokens.access));
          expect((await other.query(r'RETURN $auth.email')).single, isNotNull);
        });
      });
    }

    test('tokens are renewed before they expire', () async {
      final db = Surreal();
      addTearDown(db.close);
      await db.connect(wsUrl,
          options: const ConnectOptions(
            namespace: 'test',
            database: 'test',
            tokenExpiryMargin: Duration(seconds: 1),
          ));
      final first = await db.signup(newAccount());
      final renewed = db.authChanges.firstWhere(
          (tokens) => tokens != null && tokens.access != first.access);

      final tokens = await renewed.timeout(const Duration(seconds: 5));
      expect(tokens!.refresh, isNot(first.refresh));
      // Well past the first token's expiry, the session still works.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect((await db.query(r'RETURN $auth.email')).single, isNotNull);
    });
  }, skip: skipIntegration);
}
