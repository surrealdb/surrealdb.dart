# surrealdb.dart

A Dart and Flutter client for [SurrealDB](https://surrealdb.com) and the
[Agent Memory](https://surrealdb.com/agent-memory) API.

The SDK works with any Dart project and on every Flutter target (Android, iOS,
web, and desktop), since it depends only on portable packages.

## Features

- WebSocket and HTTP engines, selected automatically by the connection URL.
- Live queries delivered as a Dart `Stream`, with automatic reconnect and
  restart on the WebSocket engine.
- The full RPC surface: `use`, `signin`, `signup`, `authenticate`, `invalidate`,
  `info`, `set`, `unset`, `query`, `select`, `create`, `insert`,
  `insertRelation`, `update`, `upsert`, `merge`, `patch`, `delete`, `relate`,
  `run`, `live`, `kill`, `import`, `export`, `version`, and `health`.
- Native data types: `RecordId`, `StringRecordId`, `Table`, `Range`, `Uuid`,
  `Decimal`, `SurrealDuration`, `SurrealDateTime`, `SurrealFuture`, `FileRef`,
  and the geometry types, all carried losslessly through the CBOR codec.
- Record access, system user, and bearer authentication.
- A standalone client for the Agent Memory API.

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  surrealdb:
```

Then fetch it:

```sh
dart pub get
# or, in a Flutter project
flutter pub get
```

## Getting started

Start a local server for development:

```sh
surreal start --user root --pass root memory
```

Connect, select a namespace and database, authenticate, and run operations:

```dart
import 'package:surrealdb/surrealdb.dart';

Future<void> main() async {
  final db = Surreal();

  await db.connect('ws://127.0.0.1:8000/rpc');
  await db.use(namespace: 'test', database: 'test');
  await db.signin(const RootAuth(username: 'root', password: 'root'));

  // Create a record with an explicit id.
  await db.create(const RecordId('person', 'tobie'), {'name': 'Tobie'});

  // Create a record with a generated id by targeting the table.
  await db.create('person', {'name': 'Jaime'});

  // Merge a partial update.
  await db.merge(const RecordId('person', 'tobie'), {'age': 32});

  // Run a query with bound parameters.
  final results = await db.query(
    r'SELECT * FROM person WHERE age > $min',
    bindings: {'min': 18},
  );
  print(results.first);

  await db.close();
}
```

A fresh server has no namespace or database until you define them. On a new
instance, run this once after signing in:

```dart
await db.query('DEFINE NAMESPACE IF NOT EXISTS test; '
    'USE NS test; DEFINE DATABASE IF NOT EXISTS test;');
```

A record id resource returns a single record (or null), while a table or range
resource returns a list. Pass a `String` containing a colon, such as
`'person:tobie'`, and it is treated as a record id; otherwise it is treated as a
table name.

### Live queries

```dart
final live = await db.live('person');

final subscription = live.stream.listen((message) {
  print('${message.action.name}: ${message.value}');
});

// later
await subscription.cancel();
await live.kill();
```

Live queries require the WebSocket engine. Calling `live` over the HTTP engine
throws an `UnsupportedFeatureError`.

### Serialization format

The driver speaks CBOR by default, which carries the SurrealDB types without
loss. You can switch to JSON, which is easier to inspect on the wire but lossy
(record ids, datetimes, durations, and decimals come back as strings):

```dart
await db.connect(
  'ws://127.0.0.1:8000/rpc',
  options: const ConnectOptions(format: SurrealFormat.json),
);
```

The format sets the WebSocket subprotocol and the HTTP content type. To plug in
your own serialization, implement `SurrealCodec` and pass it as
`ConnectOptions(codec: ...)`.

### Authentication

```dart
// Root, namespace, or database user.
await db.signin(const RootAuth(username: 'root', password: 'root'));

// Record access, for application end users.
await db.signin(const AccessRecordAuth(
  namespace: 'test',
  database: 'test',
  access: 'user',
  variables: {'email': 'tobie@example.com', 'password': 'secret'},
));
```

### Data types

```dart
await db.create(const RecordId('event', 'launch'), {
  'at': SurrealDateTime.now(),
  'duration': SurrealDuration.minutes(90),
  'amount': const Decimal('19.99'),
  'where': const GeometryPoint(-0.118092, 51.509865),
});
```

## Flutter

No extra setup is needed. The same API works in a Flutter app:

```dart
final db = Surreal();
await db.connect('wss://your-instance.example.com/rpc');
```

For web targets, use a `ws` or `wss` URL. The WebSocket engine uses the
platform WebSocket through `web_socket_channel`, so it runs on mobile, desktop,
and web without changes.

## Agent Memory

The Agent Memory client is a separate import and does not depend on the database
driver:

```dart
import 'package:surrealdb/memory.dart';

Future<void> main() async {
  final client = AgentMemory(
    endpoint: 'https://memory.example.com',
    context: 'acme-prod',
    apiKey: 'sp-your-key',
  );

  await client.remember('I was promoted to CTO', scopes: 'user/tobie');
  final hits = await client.recall("What is Tobie's role?", k: 10);

  await for (final chunk in client.chatStream('Tell me a story')) {
    stdout.write(chunk.delta);
  }

  client.close();
}
```

## Testing

Run the unit tests, which need no server:

```sh
dart test test/cbor test/value test/memory
```

Run the integration tests against a local server:

```sh
surreal start --user root --pass root memory
SURREAL_INTEGRATION=1 dart test test/integration
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
