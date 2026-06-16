/// A Dart and Flutter client for the Spectron agent memory API.
///
/// The entry point is the [Spectron] class. It is a standalone REST client and
/// does not depend on the SurrealDB driver.
library;

export 'src/spectron/enums.dart';
export 'src/spectron/errors.dart';
export 'src/spectron/idempotency.dart' show idempotencyKey;
export 'src/spectron/scope.dart' show Scope, normaliseScope;
export 'src/spectron/spectron.dart';
export 'src/spectron/streaming.dart' show ChatChunk, parseChatStream;
export 'src/spectron/transport.dart'
    show SpectronTransport, TransportOptions, spectronClientVersion;
