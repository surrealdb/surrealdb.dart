import 'dart:async';

import 'package:http/http.dart' as http;

import 'enums.dart';
import 'scope.dart';
import 'streaming.dart';
import 'transport.dart';

/// A single message in a batch passed to [Spectron.rememberMany].
class BatchMessage {
  const BatchMessage(
      {required this.role, required this.content, this.timestamp});

  final TurnRole role;
  final String content;
  final DateTime? timestamp;

  Map<String, dynamic> toJson() => {
        'role': role.wire,
        'content': content,
        if (timestamp != null) 'ts': timestamp!.toUtc().toIso8601String(),
      };
}

/// A knowledge graph triple passed to [Spectron.remember].
class Triple {
  const Triple({
    required this.entityType,
    required this.entityName,
    required this.key,
    this.value,
    this.memoryCategory,
    this.target,
  });

  final String entityType;
  final String entityName;
  final String key;
  final Object? value;
  final MemoryCategory? memoryCategory;
  final String? target;

  Map<String, dynamic> toJson() => {
        'entity': {'type': entityType, 'name': entityName},
        'key': key,
        if (value != null) 'value': value,
        if (memoryCategory != null) 'memory_category': memoryCategory!.wire,
        if (target != null) 'target': target,
      };
}

/// The official client for the Spectron agent memory API.
///
/// Construct a client with an [endpoint], [context], and [apiKey], then call
/// the memory operations. The client is pinned to one context, every request
/// targets `/api/v1/{context}/...`.
///
/// ```dart
/// final client = Spectron(
///   endpoint: 'https://memory.example.com',
///   context: 'acme-prod',
///   apiKey: '...',
/// );
/// await client.remember('I was promoted to CTO', scopes: 'user/tobie');
/// final hits = await client.recall("What is Tobie's role?", k: 10);
/// ```
class Spectron {
  Spectron({
    required String endpoint,
    required this.context,
    required String apiKey,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 3,
    http.Client? httpClient,
  }) : _transport = SpectronTransport(TransportOptions(
          endpoint: _trimTrailingSlash(endpoint),
          apiKey: apiKey,
          timeout: timeout,
          maxRetries: maxRetries,
          client: httpClient,
        ));

  Spectron._fromTransport(this._transport, this.context);

  /// The context this client is pinned to.
  final String context;

  final SpectronTransport _transport;

  String get _prefix => '/api/v1/$context';

  /// Returns a client that acts on behalf of another principal. Requires the
  /// `manage` grant.
  Spectron onBehalfOf(String principalId) => Spectron._fromTransport(
        SpectronTransport(_transport.options.copyWith(onBehalfOf: principalId)),
        context,
      );

  /// Releases the underlying HTTP client.
  void close() => _transport.close();

  // ---------------------------------------------------------------------------
  // The core memory operations
  // ---------------------------------------------------------------------------

  /// Checks that the service is reachable.
  Future<void> health() async {
    await _transport.request(method: 'GET', path: '/api/v1/health');
  }

  /// Stores a memory. This operation is idempotent within a short window.
  Future<Map<String, dynamic>> remember(
    String? text, {
    InferMode? infer,
    String? sessionId,
    Scope scopes,
    TurnRole? role,
    MemoryCategory? memoryCategory,
    List<String>? labels,
    List<Triple>? triples,
  }) async {
    final body = <String, dynamic>{
      if (text != null) 'text': text,
      if (infer != null) 'infer': infer.wire,
      if (role != null) 'role': role.wire,
      if (memoryCategory != null) 'memory_category': memoryCategory.wire,
      if (labels != null) 'labels': labels,
      if (sessionId != null) 'session_id': sessionId,
      if (triples != null) 'triples': [for (final t in triples) t.toJson()],
      ..._scopeField('scopes', scopes),
    };
    return _map(await _transport.request(
        method: 'POST', path: '$_prefix/facts', body: body, idempotent: true));
  }

  /// Stores a batch of conversation messages as memories. Idempotent within a
  /// short window.
  Future<Map<String, dynamic>> rememberMany(
    List<BatchMessage> messages, {
    String? sessionId,
    Scope scopes,
    BatchExtractionMode? extract,
    InferMode? infer,
    List<String>? labels,
  }) async {
    final body = <String, dynamic>{
      'messages': [for (final m in messages) m.toJson()],
      if (extract != null) 'extract': extract.wire,
      if (infer != null) 'infer': infer.wire,
      if (labels != null) 'labels': labels,
      if (sessionId != null) 'session_id': sessionId,
      ..._scopeField('scopes', scopes),
    };
    return _map(await _transport.request(
        method: 'POST',
        path: '$_prefix/facts/batch',
        body: body,
        idempotent: true));
  }

  /// Retrieves memories that match [query].
  Future<Map<String, dynamic>> recall(
    String query, {
    int? k,
    QueryMode? mode,
    String? sessionId,
    List<String>? include,
    String? asOf,
    String? atInstant,
    List<String>? labels,
    Scope lens,
    ScopeView? scopeView,
    String? validFrom,
    String? validUntil,
    String? source,
    Map<String, dynamic>? location,
  }) async {
    final body = <String, dynamic>{
      'query': query,
      if (k != null) 'k': k,
      if (mode != null) 'mode': mode.wire,
      if (sessionId != null) 'sessionId': sessionId,
      if (include != null) 'include': include,
      if (asOf != null) 'asOf': asOf,
      if (atInstant != null) 'atInstant': atInstant,
      if (labels != null) 'labels': labels,
      if (scopeView != null) 'scopeView': scopeView.wire,
      if (validFrom != null) 'validFrom': validFrom,
      if (validUntil != null) 'validUntil': validUntil,
      if (source != null) 'source': source,
      if (location != null) 'location': location,
      ..._scopeField('lens', lens),
    };
    return _map(await _transport.request(
        method: 'POST', path: '$_prefix/query', body: body));
  }

  /// Removes memories that match [query].
  Future<Map<String, dynamic>> forget(String query, {bool? purge}) async {
    return _map(await _transport.request(
        method: 'POST',
        path: '$_prefix/forget',
        body: {'query': query, if (purge != null) 'purge': purge}));
  }

  /// Sends a chat message and returns the full reply.
  Future<Map<String, dynamic>> chat(
    String message, {
    String? sessionId,
    Scope scopes,
    String? model,
    bool? bypassCache,
    List<String>? labels,
  }) async {
    return _map(await _transport.request(
        method: 'POST',
        path: '$_prefix/chat',
        body: _chatBody(
          message,
          sessionId: sessionId,
          scopes: scopes,
          model: model,
          bypassCache: bypassCache,
          labels: labels,
        )));
  }

  /// Sends a chat message and streams the reply as it is generated.
  Stream<ChatChunk> chatStream(
    String message, {
    String? sessionId,
    Scope scopes,
    String? model,
    bool? bypassCache,
    List<String>? labels,
  }) async* {
    final byteStream = await _transport.stream(
      method: 'POST',
      path: '$_prefix/chat',
      body: _chatBody(
        message,
        sessionId: sessionId,
        scopes: scopes,
        model: model,
        bypassCache: bypassCache,
        labels: labels,
        stream: true,
      ),
    );
    yield* parseChatStream(byteStream);
  }

  Map<String, dynamic> _chatBody(
    String message, {
    String? sessionId,
    Scope scopes,
    String? model,
    bool? bypassCache,
    List<String>? labels,
    bool? stream,
  }) =>
      {
        'message': message,
        if (sessionId != null) 'sessionId': sessionId,
        if (model != null) 'model': model,
        if (bypassCache != null) 'bypassCache': bypassCache,
        if (labels != null) 'labels': labels,
        if (stream != null) 'stream': stream,
        ..._scopeField('scopes', scopes),
      };

  /// Builds working context for [query].
  Future<Map<String, dynamic>> contextQuery(
    String query, {
    int? k,
    List<String>? labels,
    Scope lens,
    ScopeView? scopeView,
  }) async {
    return _map(await _transport
        .request(method: 'POST', path: '$_prefix/context', body: {
      'query': query,
      if (k != null) 'k': k,
      if (labels != null) 'labels': labels,
      if (scopeView != null) 'scopeView': scopeView.wire,
      ..._scopeField('lens', lens),
    }));
  }

  /// Reflects over memories to answer [query].
  Future<Map<String, dynamic>> reflect(String query, {bool? persist}) async {
    return _map(await _transport.request(
        method: 'POST',
        path: '$_prefix/reflect',
        body: {'query': query, if (persist != null) 'persist': persist}));
  }

  /// Runs consolidation maintenance.
  Future<Map<String, dynamic>> consolidate({
    bool? dryRun,
    int? factLimit,
    int? observationLimit,
  }) async {
    return _map(await _transport
        .request(method: 'POST', path: '$_prefix/consolidate', body: {
      if (dryRun != null) 'dryRun': dryRun,
      if (factLimit != null) 'factLimit': factLimit,
      if (observationLimit != null) 'observationLimit': observationLimit,
    }));
  }

  /// Runs elaboration maintenance.
  Future<Map<String, dynamic>> elaborate({
    String? entityRef,
    int? budget,
    bool? sweep,
    bool? dryRun,
  }) async {
    return _map(await _transport
        .request(method: 'POST', path: '$_prefix/elaborate', body: {
      if (entityRef != null) 'entityRef': entityRef,
      if (budget != null) 'budget': budget,
      if (sweep != null) 'sweep': sweep,
      if (dryRun != null) 'dryRun': dryRun,
    }));
  }

  /// Runs a consistency check over stored memories.
  Future<Map<String, dynamic>> fsck({
    List<String>? check,
    double? duplicateThreshold,
    int? maxResults,
  }) async {
    return _map(
        await _transport.request(method: 'POST', path: '$_prefix/fsck', body: {
      if (check != null) 'check': check,
      if (duplicateThreshold != null) 'duplicateThreshold': duplicateThreshold,
      if (maxResults != null) 'maxResults': maxResults,
    }));
  }

  /// Inspects the history of a single reference.
  Future<Map<String, dynamic>> inspect(
    String ref, {
    String? asOf,
    String? atInstant,
    String? validFrom,
    String? validUntil,
  }) async {
    return _map(await _transport
        .request(method: 'GET', path: '$_prefix/inspect', query: {
      'ref': ref,
      if (asOf != null) 'asOf': asOf,
      if (atInstant != null) 'atInstant': atInstant,
      if (validFrom != null) 'validFrom': validFrom,
      if (validUntil != null) 'validUntil': validUntil,
    }));
  }

  /// Returns the audit log.
  Future<Map<String, dynamic>> audit({
    String? principal,
    String? key,
    String? kind,
    String? since,
    String? until,
    int? limit,
  }) async {
    return _map(
        await _transport.request(method: 'GET', path: '$_prefix/audit', query: {
      if (principal != null) 'principal': principal,
      if (key != null) 'key': key,
      if (kind != null) 'kind': kind,
      if (since != null) 'since': since,
      if (until != null) 'until': until,
      if (limit != null) 'limit': '$limit',
    }));
  }

  /// Returns the current memory state summary.
  Future<Map<String, dynamic>> state() async =>
      _map(await _transport.request(method: 'GET', path: '$_prefix/state'));

  /// Returns the current profile summary.
  Future<Map<String, dynamic>> profile() async =>
      _map(await _transport.request(method: 'GET', path: '$_prefix/profile'));

  /// Returns information about the authenticated principal.
  Future<Map<String, dynamic>> whoami() async =>
      _map(await _transport.request(method: 'GET', path: '$_prefix/me'));

  // ---------------------------------------------------------------------------
  // Namespaces
  // ---------------------------------------------------------------------------

  /// Document upload, processing, and retrieval.
  Documents get documents => Documents(_transport, _prefix);

  /// Knowledge graph entities.
  Entities get entities => Entities(_transport, _prefix);

  /// Conversation sessions.
  Sessions get sessions => Sessions(_transport, _prefix);

  /// Memory lifecycle maintenance.
  Lifecycle get lifecycle => Lifecycle(_transport, _prefix);

  /// Operation traces.
  Traces get traces => Traces(_transport, _prefix);

  /// Principals and their grants.
  Principals get principals => Principals(_transport, _prefix);

  /// Scope registration and management.
  Scopes get scopes => Scopes(_transport, _prefix);

  /// API key management.
  Keys get keys => Keys(_transport, _prefix);

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _trimTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

Map<String, dynamic> _scopeField(String field, Scope scope) {
  final normalised = normaliseScope(scope);
  return normalised == null ? const {} : {field: normalised};
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.cast<Map<String, dynamic>>() : const [];

/// Document operations under `/documents`.
class Documents {
  Documents(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  /// Document keyword operations.
  DocumentKeywords get keywords => DocumentKeywords(_transport, _prefix);

  /// Uploads a document. The bytes are sent as a multipart file with the
  /// metadata part written first.
  Future<Map<String, dynamic>> upload({
    required List<int> file,
    String? contentType,
    String? filename,
    String? title,
    String? source,
    Scope scopes,
    List<String>? labels,
  }) async {
    final metadata = <String, dynamic>{
      if (title != null) 'title': title,
      if (source != null) 'source': source,
      if (contentType != null) 'contentType': contentType,
      if (filename != null) 'filename': filename,
      if (labels != null) 'labels': labels,
      ..._scopeField('scopes', scopes),
    };
    return _map(await _transport.upload(
      path: '$_prefix/documents',
      metadata: metadata,
      bytes: file,
      filename: filename ?? 'file',
    ));
  }

  /// Reprocesses an existing document.
  Future<Map<String, dynamic>> reprocess(String id) async =>
      _map(await _transport.request(
          method: 'POST', path: '$_prefix/documents/$id/reprocess'));

  /// Returns a document by id.
  Future<Map<String, dynamic>> get(String id) async => _map(
      await _transport.request(method: 'GET', path: '$_prefix/documents/$id'));

  /// Returns the raw bytes of a document.
  Future<List<int>> raw(String id) =>
      _transport.bytes(method: 'GET', path: '$_prefix/documents/$id/raw');

  /// Returns the chunks of a document.
  Future<Map<String, dynamic>> chunks(String id,
          {int? page, int? pageSize}) async =>
      _map(await _transport.request(
          method: 'GET',
          path: '$_prefix/documents/$id/chunks',
          query: {
            if (page != null) 'page': '$page',
            if (pageSize != null) 'pageSize': '$pageSize',
          }));

  /// Lists documents.
  Future<Map<String, dynamic>> list({
    String? status,
    String? mimeType,
    int? page,
    int? pageSize,
  }) async =>
      _map(await _transport
          .request(method: 'GET', path: '$_prefix/documents', query: {
        if (status != null) 'status': status,
        if (mimeType != null) 'mimeType': mimeType,
        if (page != null) 'page': '$page',
        if (pageSize != null) 'pageSize': '$pageSize',
      }));

  /// Deletes a document.
  Future<void> delete(String id) async {
    await _transport.request(method: 'DELETE', path: '$_prefix/documents/$id');
  }

  /// Recomputes the links between documents.
  Future<Map<String, dynamic>> recomputeLinks() async => _map(await _transport
      .request(method: 'POST', path: '$_prefix/documents/recompute-links'));
}

/// Document keyword operations under `/documents/keywords`.
class DocumentKeywords {
  DocumentKeywords(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<Map<String, dynamic>> list({
    String? q,
    int? minDocumentCount,
    String? sort,
    int? page,
    int? pageSize,
  }) async =>
      _map(await _transport
          .request(method: 'GET', path: '$_prefix/documents/keywords', query: {
        if (q != null) 'q': q,
        if (minDocumentCount != null) 'minDocumentCount': '$minDocumentCount',
        if (sort != null) 'sort': sort,
        if (page != null) 'page': '$page',
        if (pageSize != null) 'pageSize': '$pageSize',
      }));

  Future<Map<String, dynamic>> get(String normalised) async =>
      _map(await _transport.request(
          method: 'GET', path: '$_prefix/documents/keywords/$normalised'));

  Future<Map<String, dynamic>> forDocument(String documentId) async =>
      _map(await _transport.request(
          method: 'GET', path: '$_prefix/documents/$documentId/keywords'));
}

/// Entity operations under `/entities`.
class Entities {
  Entities(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<Map<String, dynamic>> list({String? type}) async =>
      _map(await _transport.request(
          method: 'GET',
          path: '$_prefix/entities',
          query: {if (type != null) 'type': type}));

  Future<Map<String, dynamic>> get(String entityType, String name) async =>
      _map(await _transport.request(
          method: 'GET', path: '$_prefix/entities/$entityType/$name'));

  Future<Map<String, dynamic>> history(
          String entityType, String name, String key) async =>
      _map(await _transport.request(
          method: 'GET',
          path: '$_prefix/entities/$entityType/$name/history/$key'));

  Future<void> delete(String entityType, String name) async {
    await _transport.request(
        method: 'DELETE', path: '$_prefix/entities/$entityType/$name');
  }
}

/// Session operations under `/sessions`.
class Sessions {
  Sessions(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<Map<String, dynamic>> create({
    Scope scopes,
    Map<String, dynamic>? metadata,
  }) async =>
      _map(await _transport
          .request(method: 'POST', path: '$_prefix/sessions', body: {
        if (metadata != null) 'metadata': metadata,
        ..._scopeField('scopes', scopes),
      }));

  Future<void> close(String id) async {
    await _transport.request(
        method: 'POST', path: '$_prefix/sessions/$id/close');
  }

  Future<Map<String, dynamic>> turns(String id) async => _map(await _transport
      .request(method: 'GET', path: '$_prefix/sessions/$id/turns'));

  Future<Map<String, dynamic>> context(String id,
          {required String query}) async =>
      _map(await _transport.request(
          method: 'POST',
          path: '$_prefix/sessions/$id/context',
          body: {'query': query}));
}

/// Lifecycle maintenance under `/lifecycle`.
class Lifecycle {
  Lifecycle(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<Map<String, dynamic>> expire() async => _map(await _transport.request(
      method: 'POST', path: '$_prefix/lifecycle/expire'));

  Future<Map<String, dynamic>> decay() async => _map(await _transport.request(
      method: 'POST', path: '$_prefix/lifecycle/decay'));
}

/// Trace operations under `/traces`.
class Traces {
  Traces(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<Map<String, dynamic>> list({int? limit}) async =>
      _map(await _transport.request(
          method: 'GET',
          path: '$_prefix/traces',
          query: {if (limit != null) 'limit': '$limit'}));

  Future<Map<String, dynamic>> get(String traceId) async =>
      _map(await _transport.request(
          method: 'GET', path: '$_prefix/traces/$traceId'));

  Future<Map<String, dynamic>> stats() async => _map(
      await _transport.request(method: 'GET', path: '$_prefix/traces/stats'));
}

/// Principal operations under `/principals`.
class Principals {
  Principals(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<List<Map<String, dynamic>>> list() async => _list(
      await _transport.request(method: 'GET', path: '$_prefix/principals'));

  Future<Map<String, dynamic>> get(String id) async => _map(
      await _transport.request(method: 'GET', path: '$_prefix/principals/$id'));

  Future<Map<String, dynamic>> effective(String id,
          {required String path, String? asOf}) async =>
      _map(await _transport.request(
          method: 'GET',
          path: '$_prefix/principals/$id/effective',
          query: {'path': path, if (asOf != null) 'asOf': asOf}));

  Future<Map<String, dynamic>> grant(String id,
          {required String path, required List<Verb> verbs}) async =>
      _map(await _transport.request(
          method: 'POST',
          path: '$_prefix/principals/$id/grant',
          body: {
            'path': path,
            'verbs': [for (final v in verbs) v.wire]
          }));

  Future<Map<String, dynamic>> revoke(String id,
          {required String path, required List<Verb> verbs}) async =>
      _map(await _transport.request(
          method: 'POST',
          path: '$_prefix/principals/$id/revoke',
          body: {
            'path': path,
            'verbs': [for (final v in verbs) v.wire]
          }));
}

/// Scope operations under `/scopes`.
class Scopes {
  Scopes(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<List<Map<String, dynamic>>> list() async =>
      _list(await _transport.request(method: 'GET', path: '$_prefix/scopes'));

  Future<Map<String, dynamic>> register({
    required String path,
    String? displayName,
    String? description,
  }) async =>
      _map(await _transport
          .request(method: 'POST', path: '$_prefix/scopes', body: {
        'path': path,
        if (displayName != null) 'displayName': displayName,
        if (description != null) 'description': description,
      }));

  Future<void> delete(String path) async {
    await _transport.request(
        method: 'DELETE', path: '$_prefix/scopes', query: {'path': path});
  }

  Future<Map<String, dynamic>> forget({String? path}) async =>
      _map(await _transport.request(
          method: 'POST',
          path: '$_prefix/scopes/forget',
          body: {if (path != null) 'path': path}));
}

/// API key operations under `/keys`.
class Keys {
  Keys(this._transport, this._prefix);

  final SpectronTransport _transport;
  final String _prefix;

  Future<Map<String, dynamic>> create({
    String? name,
    List<Map<String, dynamic>>? grants,
    int? ttlSeconds,
  }) async =>
      _map(await _transport
          .request(method: 'POST', path: '$_prefix/keys', body: {
        if (name != null) 'name': name,
        if (grants != null) 'grants': grants,
        if (ttlSeconds != null) 'ttlSeconds': ttlSeconds,
      }));

  Future<List<Map<String, dynamic>>> list() async =>
      _list(await _transport.request(method: 'GET', path: '$_prefix/keys'));

  Future<void> delete(String name) async {
    await _transport.request(method: 'DELETE', path: '$_prefix/keys/$name');
  }

  Future<Map<String, dynamic>> rotate(String name, {int? ttlSeconds}) async =>
      _map(await _transport.request(
          method: 'POST',
          path: '$_prefix/keys/$name/rotate',
          body: {if (ttlSeconds != null) 'ttlSeconds': ttlSeconds}));
}
