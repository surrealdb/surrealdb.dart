/// How much inference Spectron should run when storing a memory.
enum InferMode {
  full('full'),
  triples('triples'),
  preview('preview'),
  none('none');

  const InferMode(this.wire);

  /// The value sent on the wire.
  final String wire;
}

/// How a batch of messages is turned into memories.
enum BatchExtractionMode {
  perMessage('per_message'),
  wholeConversation('whole_conversation');

  const BatchExtractionMode(this.wire);

  final String wire;
}

/// The category a memory belongs to.
enum MemoryCategory {
  identity('identity'),
  knowledge('knowledge'),
  context('context');

  const MemoryCategory(this.wire);

  final String wire;
}

/// The role of a message in a conversation.
enum TurnRole {
  user('user'),
  assistant('assistant'),
  system('system'),
  tool('tool');

  const TurnRole(this.wire);

  final String wire;
}

/// The retrieval strategy used by a query.
enum QueryMode {
  hybrid('hybrid'),
  vector('vector'),
  bm25('bm25'),
  hybridGraph('hybrid_graph');

  const QueryMode(this.wire);

  final String wire;
}

/// A permission verb used in access grants.
enum Verb {
  read('read'),
  write('write'),
  createScope('create_scope'),
  deleteScope('delete_scope'),
  grant('grant'),
  manage('manage'),
  forget('forget');

  const Verb(this.wire);

  final String wire;
}

/// How scopes are combined when reading.
enum ScopeView {
  strict('strict'),
  merged('merged'),
  crossTeam('crossTeam');

  const ScopeView(this.wire);

  final String wire;
}

/// The processing state of an uploaded document.
enum DocumentStatus {
  queued('queued'),
  extracting('extracting'),
  chunking('chunking'),
  embedding('embedding'),
  keywording('keywording'),
  extractingNodes('extracting_nodes'),
  ready('ready'),
  failed('failed');

  const DocumentStatus(this.wire);

  final String wire;

  /// Parses the status string sent by the server.
  static DocumentStatus parse(String value) =>
      values.firstWhere((status) => status.wire == value,
          orElse: () => DocumentStatus.queued);
}
