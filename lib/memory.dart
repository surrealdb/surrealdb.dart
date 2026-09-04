/// A Dart and Flutter client for the SurrealDB Agent Memory API.
///
/// The entry point is the [AgentMemory] class. It is a standalone REST client
/// and does not depend on the SurrealDB driver.
library;

export 'src/memory/agent_memory.dart';
export 'src/memory/enums.dart';
export 'src/memory/errors.dart';
export 'src/memory/idempotency.dart' show idempotencyKey;
export 'src/memory/scope.dart' show Scope, normaliseScope;
export 'src/memory/streaming.dart' show ChatChunk, parseChatStream;
export 'src/memory/transport.dart'
    show AgentMemoryTransport, TransportOptions, agentMemoryClientVersion;
