@TestOn('vm')
library;

import 'package:surrealdb/src/internal/jwt.dart';
import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

void main() {
  group('jwt', () {
    test('reads the expiry', () {
      final token = fakeJwt(const Duration(hours: 1));
      final expiry = tokenExpiry(token)!;
      expect(expiry.difference(DateTime.now()).inMinutes,
          inInclusiveRange(59, 60));
      expect(tokenExpiry('not a jwt'), isNull);
    });

    test('renews a margin early, or halfway for short tokens', () {
      final now = DateTime.utc(2026);
      const margin = Duration(seconds: 60);
      expect(renewalDelay(now.add(const Duration(hours: 1)), margin, now: now),
          const Duration(minutes: 59));
      expect(
          renewalDelay(now.add(const Duration(seconds: 90)), margin, now: now),
          const Duration(seconds: 45));
      expect(
          renewalDelay(now.subtract(const Duration(seconds: 1)), margin,
              now: now),
          Duration.zero);
    });
  });

  group('tokens', () {
    late FakeSurrealServer server;
    late Surreal db;
    var issued = 0;

    FakeReply issueTokens(FakeRequest request, Duration lifetime) {
      issued++;
      return FakeResult({
        'access': fakeJwt(lifetime, id: '$issued'),
        'refresh': 'refresh-$issued',
      });
    }

    setUp(() async {
      issued = 0;
      server = await FakeSurrealServer.start();
      db = Surreal();
    });

    tearDown(() async {
      await db.close();
      await server.close();
    });

    Future<void> connect({Duration margin = const Duration(seconds: 60)}) =>
        db.connect(server.url,
            options: ConnectOptions(
              versionCheck: false,
              tokenExpiryMargin: margin,
              reconnect: const ReconnectOptions(
                retryDelay: Duration(milliseconds: 10),
                retryDelayMax: Duration(milliseconds: 10),
              ),
            ));

    test('signin keeps the access and refresh tokens', () async {
      server.handler = (r) => r.method == 'signin'
          ? issueTokens(r, const Duration(hours: 1))
          : FakeSurrealServer.defaultReply(r);
      await connect();
      final tokens =
          await db.signin(const RootAuth(username: 'u', password: 'p'));
      expect(tokens.refresh, 'refresh-1');
      expect(db.tokens, tokens);
      expect(db.accessToken, tokens.access);
    });

    test('refresh sends the token pair and keeps the new one', () async {
      server.handler = (r) => switch (r.method) {
            'signin' || 'refresh' => issueTokens(r, const Duration(hours: 1)),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect();
      final first =
          await db.signin(const RootAuth(username: 'u', password: 'p'));
      final second = await db.refresh();
      expect(server.requests.last.params, [first.toJson()]);
      expect(second.refresh, 'refresh-2');
      expect(db.tokens, second);
    });

    test('revoke sends the token pair and forgets the refresh token', () async {
      server.handler = (r) => r.method == 'signin'
          ? issueTokens(r, const Duration(hours: 1))
          : FakeSurrealServer.defaultReply(r);
      await connect();
      final tokens =
          await db.signin(const RootAuth(username: 'u', password: 'p'));
      await db.revoke();
      expect(server.requests.last.method, 'revoke');
      expect(server.requests.last.params, [tokens.toJson()]);
      expect(db.tokens, Tokens(access: tokens.access));
      expect(() => db.refresh(), throwsA(isA<AuthenticationError>()));
    });

    test('renews with the refresh token before the token expires', () async {
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(seconds: 2)),
            'refresh' => issueTokens(r, const Duration(hours: 1)),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect(margin: const Duration(seconds: 1));
      final changes = <Tokens?>[];
      db.authChanges.listen(changes.add);
      await db.signin(const RootAuth(username: 'u', password: 'p'));

      await eventually(() => server.methods.contains('refresh'),
          timeout: const Duration(seconds: 3));
      await eventually(() => db.tokens?.refresh == 'refresh-2');
      expect(changes.last?.refresh, 'refresh-2');
    });

    test('a renewal under way cannot undo a later sign-out', () async {
      FakeRequest? held;
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(seconds: 2)),
            'refresh' => () {
                held = r;
                return const FakeSilence();
              }(),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect(margin: const Duration(seconds: 1));
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      await eventually(() => held != null, timeout: const Duration(seconds: 3));

      final signedOut = db.invalidate();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The sign-out waits for the renewal rather than racing it.
      expect(server.methods, isNot(contains('invalidate')));
      held!.socket.add(const CborCodec().encode({
        'id': held!.id,
        'result': {
          'access': fakeJwt(const Duration(hours: 1), id: 'late'),
          'refresh': 'refresh-late',
        },
      }));
      await signedOut;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.methods.last, 'invalidate');
      expect(db.tokens, isNull);
    });

    test('a sign-out holds off a renewal that comes due during it', () async {
      FakeRequest? held;
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(seconds: 2)),
            'invalidate' => () {
                held = r;
                return const FakeSilence();
              }(),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect(margin: const Duration(seconds: 1));
      await db.signin(const RootAuth(username: 'u', password: 'p'));

      // The renewal is due a second after signing in; sign out before then
      // and hold the reply past it.
      final signedOut = db.invalidate();
      await eventually(() => held != null);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(server.methods, isNot(contains('refresh')));
      held!.socket
          .add(const CborCodec().encode({'id': held!.id, 'result': null}));
      await signedOut;
      expect(db.tokens, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.methods, isNot(contains('refresh')));
    });

    test('authenticate publishes the token pair once', () async {
      await connect();
      final changes = <Tokens?>[];
      db.authChanges.listen(changes.add);
      final access = fakeJwt(const Duration(hours: 1), id: 'given');
      await db.authenticate(access, refreshToken: 'refresh-given');
      await Future<void>.delayed(Duration.zero);
      expect(changes, [Tokens(access: access, refresh: 'refresh-given')]);
    });

    test('renews by signing in again when there is no refresh token', () async {
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(const Duration(seconds: 1)))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
          ));
      await eventually(
          () => server.methods.where((m) => m == 'signin').length >= 2,
          timeout: const Duration(seconds: 3));
    });

    test('does not renew tokens when renewal is off', () async {
      server.handler = (r) => r.method == 'signin'
          ? issueTokens(r, const Duration(milliseconds: 300))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options:
              const ConnectOptions(versionCheck: false, renewTokens: false));
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(server.methods, isNot(contains('refresh')));
    });

    test('a reconnect with an expired token refreshes it', () async {
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(milliseconds: 1)),
            'refresh' => issueTokens(r, const Duration(hours: 1)),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            renewTokens: false,
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      final first =
          await db.signin(const RootAuth(username: 'u', password: 'p'));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);

      expect(server.methods, ['refresh']);
      expect(server.requests.single.params, [first.toJson()]);
      expect(db.tokens?.refresh, 'refresh-2');
    });

    test('a reconnect whose token is rejected falls back to refresh', () async {
      server.handler = (r) => switch (r.method) {
            'signin' || 'refresh' => issueTokens(r, const Duration(hours: 1)),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect();
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      server.handler = (r) => switch (r.method) {
            'authenticate' => const FakeError('Token expired',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            'refresh' => issueTokens(r, const Duration(hours: 1)),
            _ => FakeSurrealServer.defaultReply(r),
          };
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);

      expect(server.methods, ['authenticate', 'refresh']);
      expect(db.tokens?.refresh, 'refresh-2');
    });

    test('authenticate with an expired token and a refresh token refreshes',
        () async {
      server.handler = (r) => r.method == 'refresh'
          ? issueTokens(r, const Duration(hours: 1))
          : FakeSurrealServer.defaultReply(r);
      await connect();
      final expired = fakeJwt(const Duration(seconds: -10));
      await db.authenticate(expired, refreshToken: 'old');
      expect(server.methods.last, 'refresh');
      expect(server.requests.last.params, [
        {'access': expired, 'refresh': 'old'},
      ]);
      expect(db.tokens?.refresh, 'refresh-1');
    });
  });
}
