import 'dart:async';
import 'dart:convert';

/// One chunk of a streaming chat response.
class ChatChunk {
  const ChatChunk({
    required this.delta,
    required this.done,
    this.traceId,
    this.sessionId,
    this.raw,
  });

  /// The text added by this chunk.
  final String delta;

  /// Whether this is the final chunk.
  final bool done;

  /// The trace id, when the server includes it.
  final String? traceId;

  /// The session id, when the server includes it.
  final String? sessionId;

  /// The decoded frame, for fields not surfaced directly.
  final Map<String, dynamic>? raw;
}

/// Parses a server sent events byte stream into [ChatChunk]s.
///
/// Frames are separated by a blank line. Within a frame, `data:` lines are
/// collected and comment lines beginning with `:` are skipped. A `[DONE]`
/// sentinel ends the stream. A frame that is not valid JSON is treated as a
/// plain text delta.
Stream<ChatChunk> parseChatStream(Stream<List<int>> byteStream) async* {
  var buffer = '';
  await for (final bytes in byteStream) {
    buffer += utf8.decode(bytes, allowMalformed: true);
    var index = buffer.indexOf(_frameBoundary);
    while (index != -1) {
      final frame = buffer.substring(0, index);
      buffer = buffer.substring(index + _frameBoundary.length);
      final chunk = _parseFrame(frame);
      if (chunk != null) {
        yield chunk;
        if (chunk.done) return;
      }
      index = buffer.indexOf(_frameBoundary);
    }
  }
  final tail = _parseFrame(buffer);
  if (tail != null) yield tail;
}

const String _frameBoundary = '\n\n';

ChatChunk? _parseFrame(String frame) {
  final dataLines = <String>[];
  for (final raw in frame.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty || line.startsWith(':')) continue;
    if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).trimLeft());
    }
  }
  if (dataLines.isEmpty) return null;

  final payload = dataLines.join('\n');
  if (payload == '[DONE]') {
    return const ChatChunk(delta: '', done: true);
  }

  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      return ChatChunk(
        delta: (decoded['delta'] ?? decoded['token'] ?? '').toString(),
        done: decoded['done'] == true,
        traceId: (decoded['traceId'] ?? decoded['trace_id'])?.toString(),
        sessionId: (decoded['sessionId'] ?? decoded['session_id'])?.toString(),
        raw: decoded,
      );
    }
  } on FormatException {
    // Not JSON, fall through and treat the payload as a plain delta.
  }
  return ChatChunk(delta: payload, done: false);
}
