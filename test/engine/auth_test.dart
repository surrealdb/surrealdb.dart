@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:surrealdb/src/internal/jwt.dart';
import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

import '../support/fake_server.dart';

/// A point, which only [_PointCodec] can encode.
class _Point {
  const _Point(this.x, this.y);
  final int x;
  final int y;
}

/// CBOR, with points encoded as `[x, y]`.
class _PointCodec extends CborCodec {
  const _PointCodec();

  static Object? _points(Object? value) => switch (value) {
        _Point(:final x, :final y) => [x, y],
        Map() => {
            for (final MapEntry(:key, :value) in value.entries)
              key: _points(value),
          },
        List() => [for (final item in value) _points(item)],
        _ => value,
      };

  @override
  Uint8List encode(Object? value) => super.encode(_points(value));
}

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
          ? issueTokens(r, const Duration(seconds: 1))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options:
              const ConnectOptions(versionCheck: false, renewTokens: false));
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      await db.revoke();
      expect(db.tokens, isNotNull);
      // Signed out once the token expires, without trying to renew it.
      await eventually(() => db.tokens == null,
          timeout: const Duration(seconds: 3));
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

    test('a reconnect that cannot check the token keeps it and tries again',
        () async {
      server.handler = (r) => r.method == 'signin'
          ? issueTokens(r, const Duration(hours: 1))
          : FakeSurrealServer.defaultReply(r);
      await connect();
      final tokens =
          await db.signin(const RootAuth(username: 'u', password: 'p'));
      var failures = 0;
      server.handler = (r) => r.method == 'authenticate' && failures++ == 0
          ? const FakeError('There was a problem with the datastore',
              extra: {'kind': 'Internal'})
          : FakeSurrealServer.defaultReply(r);
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 3);
      expect(server.methods, ['authenticate', 'authenticate']);
      expect(db.tokens, tokens);
    });

    test('a reconnect whose token is rejected signs in again', () async {
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}'))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      final before = db.tokens;
      server.handler = (r) => switch (r.method) {
            'authenticate' => const FakeError('The token has expired',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            'signin' =>
              FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}')),
            _ => FakeSurrealServer.defaultReply(r),
          };
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 2);
      expect(server.methods, ['authenticate', 'signin']);
      expect(server.requests.last.params, [
        {'user': 'u', 'pass': 'p'},
      ]);
      expect(db.tokens, isNotNull);
      expect(db.tokens, isNot(before));
    });

    test('a failed sign-in keeps renewing the session it left alone', () async {
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(const Duration(seconds: 2), id: '${++issued}'))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
          ));
      server.handler = (r) => r.method == 'signin' &&
              (r.params.first as Map)['user'] == 'other'
          ? const FakeError('There was a problem with authentication',
              code: -32002, extra: {'kind': 'NotAllowed'})
          : r.method == 'signin'
              ? FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}'))
              : FakeSurrealServer.defaultReply(r);
      await expectLater(
          db.signin(const RootAuth(username: 'other', password: 'x')),
          throwsA(isA<NotAllowedError>()));

      await eventually(
          () =>
              server.requests
                  .where((r) =>
                      r.method == 'signin' &&
                      (r.params.first as Map)['user'] == 'u')
                  .length ==
              2,
          timeout: const Duration(seconds: 3));
    });

    test('overlapping authenticate calls each keep their refresh token',
        () async {
      await connect();
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'authenticate' && held == null) {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      final first = fakeJwt(const Duration(hours: 1), id: 'a');
      final second = fakeJwt(const Duration(hours: 1), id: 'b');
      final firstCall = db.authenticate(first, refreshToken: 'r-a');
      final secondCall = db.authenticate(second, refreshToken: 'r-b');
      await eventually(() => held != null);
      // The second waits for the first.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.methods.where((m) => m == 'authenticate'), hasLength(1));

      held!.socket
          .add(const CborCodec().encode({'id': held!.id, 'result': null}));
      await firstCall;
      expect(db.tokens, Tokens(access: first, refresh: 'r-a'));
      await secondCall;
      expect(db.tokens, Tokens(access: second, refresh: 'r-b'));
    });

    test('a renewal that fails is tried again after the token expires',
        () async {
      var failures = 0;
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(seconds: 1)),
            'refresh' when failures++ == 0 => const FakeError(
                'There was a problem with the datastore',
                extra: {'kind': 'Internal'}),
            'refresh' => issueTokens(r, const Duration(hours: 1)),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect();
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      await eventually(() => db.tokens?.refresh == 'refresh-2',
          timeout: const Duration(seconds: 8));
      expect(server.methods.where((m) => m == 'refresh'), hasLength(2));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a session whose renewal is rejected is signed out when it expires',
        () async {
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(seconds: 1)),
            'refresh' => const FakeError('The refresh token is not valid',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect();
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      await eventually(() => server.methods.contains('refresh'));
      await eventually(() => db.tokens == null,
          timeout: const Duration(seconds: 3));
    });

    test('a session whose refresh token is revoked is signed out at expiry',
        () async {
      server.handler = (r) => r.method == 'signin'
          ? issueTokens(r, const Duration(seconds: 1))
          : FakeSurrealServer.defaultReply(r);
      await connect(margin: const Duration(milliseconds: 100));
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      await db.revoke();
      expect(db.tokens?.refresh, isNull);
      await eventually(() => db.tokens == null,
          timeout: const Duration(seconds: 3));
      expect(server.methods, isNot(contains('refresh')));
    });

    test('a failed call keeps the sign-out at expiry', () async {
      server.handler = (r) => switch (r.method) {
            'signin' => issueTokens(r, const Duration(seconds: 2)),
            'refresh' => const FakeError('The refresh token is not valid',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await connect();
      await db.signin(const RootAuth(username: 'u', password: 'p'));
      // Renewal is rejected halfway through, which leaves only the sign-out.
      await eventually(() => db.tokens != null && db.tokens!.refresh == null);
      await expectLater(db.refresh(), throwsA(isA<AuthenticationError>()));
      await eventually(() => db.tokens == null,
          timeout: const Duration(seconds: 3));
    });

    test('a renewal that gives the same token back is tried again', () async {
      final token = fakeJwt(const Duration(seconds: 2));
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(token)
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
            tokenExpiryMargin: Duration(milliseconds: 500),
          ));
      await eventually(
          () => server.methods.where((m) => m == 'signin').length >= 2,
          timeout: const Duration(seconds: 3));
      // The retry backs off for 5 seconds, so it comes after the token has
      // expired, and the server has a fresh one by then.
      final fresh = fakeJwt(const Duration(hours: 1));
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fresh)
          : FakeSurrealServer.defaultReply(r);
      await eventually(() => db.tokens?.access == fresh,
          timeout: const Duration(seconds: 8));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('signing in again keeps what was selected since', () async {
      // Only the first token is short lived, so there is one renewal.
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(
              issued == 0
                  ? const Duration(seconds: 1)
                  : const Duration(hours: 1),
              id: '${issued++}',
              claims: {'NS': 'ns', 'DB': 'db'}))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: DatabaseAuth(
                namespace: 'ns', database: 'db', username: 'u', password: 'p'),
          ));
      expect([db.namespace, db.database], ['ns', 'db']);
      await db.use(database: 'other');
      await eventually(
          () => server.methods.where((m) => m == 'signin').length >= 2,
          timeout: const Duration(seconds: 3));
      await eventually(() => server.methods.last == 'use');
      expect(server.requests.last.params, ['ns', 'other']);
      await eventually(() => db.database == 'other');
      expect(db.namespace, 'ns');
    });

    test('signing in again uses the credentials as they were given', () async {
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(const Duration(seconds: 1), id: '${issued++}'))
          : FakeSurrealServer.defaultReply(r);
      final variables = <String, Object?>{'email': 'a@example.com'};
      await db.connect(server.url,
          options: ConnectOptions(
            versionCheck: false,
            authentication: AccessRecordAuth(
                access: 'user',
                namespace: 'ns',
                database: 'db',
                variables: variables),
          ));
      variables['email'] = 'b@example.com';
      await eventually(
          () => server.methods.where((m) => m == 'signin').length >= 2,
          timeout: const Duration(seconds: 3));
      final signins = server.requests.where((r) => r.method == 'signin');
      expect(signins.last.params, signins.first.params);
      expect((signins.last.params.single as Map)['email'], 'a@example.com');
    });

    test('a selection made during a renewal is the one that stays', () async {
      FakeRequest? held;
      var signins = 0;
      server.handler = (r) {
        if (r.method == 'signin' && ++signins == 2) {
          held = r;
          return const FakeSilence();
        }
        return r.method == 'signin'
            ? FakeResult(fakeJwt(const Duration(seconds: 1),
                claims: {'NS': 'ns', 'DB': 'db'}))
            : FakeSurrealServer.defaultReply(r);
      };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: DatabaseAuth(
                namespace: 'ns', database: 'db', username: 'u', password: 'p'),
          ));
      await eventually(() => held != null, timeout: const Duration(seconds: 3));
      final using = db.use(database: 'other');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final renewed =
          fakeJwt(const Duration(hours: 1), claims: {'NS': 'ns', 'DB': 'db'});
      held!.socket
          .add(const CborCodec().encode({'id': held!.id, 'result': renewed}));
      await using;
      await eventually(() => db.tokens?.access == renewed);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(db.database, 'other');
      expect(server.methods.last, 'use');
      expect(server.requests.last.params, ['ns', 'other']);
    });

    test('a selection lost with the connection after a renewal is made again',
        () async {
      var signins = 0;
      var silenceUse = false;
      server.handler = (r) {
        if (r.method == 'signin') {
          signins++;
          if (signins == 2) silenceUse = true;
          return FakeResult(fakeJwt(
              signins == 1
                  ? const Duration(seconds: 1)
                  : const Duration(hours: 1),
              id: '$signins',
              claims: {'NS': 'ns', 'DB': 'db'}));
        }
        if (r.method == 'use' && silenceUse) {
          silenceUse = false;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            requestTimeout: Duration(milliseconds: 300),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
            authentication: DatabaseAuth(
                namespace: 'ns', database: 'db', username: 'u', password: 'p'),
          ));
      await db.use(database: 'other');
      await eventually(() => server.accepted == 2,
          timeout: const Duration(seconds: 3));
      await eventually(() => db.status == ConnectionStatus.connected);
      expect(db.database, 'other');
      final replayed = server.requests.where((r) => r.method == 'use').last;
      expect(replayed.params, ['ns', 'other']);
    });

    test('a renewal does not start while the last one is selecting again',
        () async {
      var signins = 0;
      var replied = false;
      bool? overlapped;
      server.handler = (r) {
        if (r.method == 'signin') {
          signins++;
          if (signins == 3) overlapped = !replied;
          return FakeResult(fakeJwt(
              switch (signins) {
                1 => const Duration(seconds: 1),
                2 => const Duration(milliseconds: 400),
                _ => const Duration(hours: 1),
              },
              id: '$signins',
              claims: {'NS': 'ns', 'DB': 'db'}));
        }
        if (r.method == 'use' && signins == 2) {
          // The selection is made again slowly, past the next renewal.
          Timer(const Duration(milliseconds: 600), () {
            replied = true;
            r.socket
                .add(const CborCodec().encode({'id': r.id, 'result': null}));
          });
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: DatabaseAuth(
                namespace: 'ns', database: 'db', username: 'u', password: 'p'),
          ));
      await db.use(database: 'other');
      await eventually(() => signins >= 3, timeout: const Duration(seconds: 4));
      expect(overlapped, isFalse);
    });

    test('a selection lost as the client closes is not kept', () async {
      var signins = 0;
      FakeRequest? held;
      server.handler = (r) {
        if (r.method == 'signin') {
          signins++;
          return FakeResult(fakeJwt(
              signins == 1
                  ? const Duration(seconds: 1)
                  : const Duration(hours: 1),
              id: '$signins',
              claims: {'NS': 'ns', 'DB': 'db'}));
        }
        if (r.method == 'use' && signins == 2) {
          held = r;
          return const FakeSilence();
        }
        return FakeSurrealServer.defaultReply(r);
      };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: DatabaseAuth(
                namespace: 'ns', database: 'db', username: 'u', password: 'p'),
          ));
      await db.use(database: 'other');
      await eventually(() => held != null, timeout: const Duration(seconds: 3));
      await db.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect([db.namespace, db.database], [null, null]);
    });

    test('credentials are copied with the codec they are sent with', () async {
      await db.connect(server.url,
          options: ConnectOptions(
            versionCheck: false,
            codec: const _PointCodec(),
            authentication: AccessRecordAuth(
                access: 'user',
                namespace: 'ns',
                database: 'db',
                variables: {'at': const _Point(1, 2)}),
          ));
      expect((server.requests.last.params.single as Map)['at'], [1, 2]);
    });

    test('a reconnect keeps the tokens until signing in again works', () async {
      server.handler = (r) => r.method == 'signin'
          ? FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}'))
          : FakeSurrealServer.defaultReply(r);
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      var failures = 0;
      server.handler = (r) => switch (r.method) {
            'authenticate' => const FakeError('The token has expired',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            'signin' when failures++ == 0 => const FakeError(
                'There was a problem with the datastore',
                extra: {'kind': 'Internal'}),
            'signin' =>
              FakeResult(fakeJwt(const Duration(hours: 1), id: '${++issued}')),
            _ => FakeSurrealServer.defaultReply(r),
          };
      server.requests.clear();

      await server.dropAll();
      await eventually(() =>
          db.status == ConnectionStatus.connected && server.accepted == 3);
      expect(
          server.methods, ['authenticate', 'signin', 'authenticate', 'signin']);
      expect(db.tokens, isNotNull);
    });

    test('a timed out refresh starts again on a new socket', () async {
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            requestTimeout: Duration(milliseconds: 300),
            reconnect: ReconnectOptions(
              retryDelay: Duration(milliseconds: 10),
              retryDelayMax: Duration(milliseconds: 10),
            ),
          ));
      server.handler = (r) => r.method == 'refresh'
          ? const FakeSilence()
          : FakeSurrealServer.defaultReply(r);
      await expectLater(db.refresh(const Tokens(access: 'a', refresh: 'r')),
          throwsA(isA<RequestTimeoutError>()));
      await eventually(() =>
          server.accepted == 2 && db.status == ConnectionStatus.connected);
    });

    test('a renewal rejected by a server before 3.0 is not retried', () async {
      var signins = 0;
      server.handler = (r) => switch (r.method) {
            'signin' when signins++ == 0 =>
              FakeResult(fakeJwt(const Duration(seconds: 1))),
            'signin' => const FakeError(
                'There was a problem with the database: There was a problem '
                'with authentication'),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
          ));
      await eventually(() => db.tokens == null,
          timeout: const Duration(seconds: 3));
      expect(signins, 2);
    });

    test('refreshing another token pair forgets the connect credentials',
        () async {
      var refreshes = 0;
      server.handler = (r) => switch (r.method) {
            'signin' => FakeResult(fakeJwt(const Duration(hours: 1))),
            'refresh' when refreshes++ == 0 => FakeResult({
                'access': fakeJwt(const Duration(seconds: 1), id: 'b'),
                'refresh': 'refresh-b',
              }),
            'refresh' => const FakeError('The refresh token is not valid',
                code: -32002, extra: {'kind': 'NotAllowed'}),
            _ => FakeSurrealServer.defaultReply(r),
          };
      await db.connect(server.url,
          options: const ConnectOptions(
            versionCheck: false,
            authentication: RootAuth(username: 'u', password: 'p'),
          ));
      await db.refresh(const Tokens(access: 'a-of-b', refresh: 'r-of-b'));
      await eventually(() => db.tokens == null,
          timeout: const Duration(seconds: 3));
      expect(server.methods.where((m) => m == 'signin'), hasLength(1));
    });
  });
}
