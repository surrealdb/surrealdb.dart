import 'dart:typed_data';

import '../errors.dart';
import '../protocol/codec.dart';
import '../types/live.dart';
import '../value/value.dart';

/// A message arriving from the server over a streaming transport. It is either
/// a [RpcResponse] to a call this client made, or a [RpcNotification] for a
/// live query.
sealed class RpcIncoming {}

/// A response correlated to a request by its [id].
final class RpcResponse extends RpcIncoming {
  RpcResponse({required this.id, this.result, this.error});

  final String id;
  final Object? result;
  final ResponseError? error;
}

/// A live query notification pushed by the server.
final class RpcNotification extends RpcIncoming {
  RpcNotification(this.message);

  final LiveMessage message;
}

/// The RPC layer shared by the engines.
///
/// It owns request id generation and the framing and decoding of the
/// `{id, method, params}` and `{id, result | error}` message shapes, on top of
/// a pluggable [SurrealCodec]. The transports keep only their own concerns:
/// the WebSocket engine correlates responses and reconnects, the HTTP engine
/// posts and reads a single response.
class RpcProtocol {
  RpcProtocol(this.codec);

  final SurrealCodec codec;
  var _counter = 0;

  /// A fresh request id.
  String nextId() => (_counter++).toString();

  /// Encodes a request envelope.
  Uint8List encodeRequest(String id, String method, List<Object?> params) =>
      codec.encode({'id': id, 'method': method, 'params': params});

  /// Decodes a single response. Used by request and response transports such as
  /// HTTP, where every message is a response.
  RpcResponse decodeResponse(List<int> bytes) {
    final decoded = codec.decode(bytes);
    final map = decoded is Map ? decoded : const {};
    return _responseFrom(map);
  }

  /// Decodes a message from a streaming transport, classifying it as a response
  /// or a live notification. Returns null for anything else.
  RpcIncoming? decodeIncoming(List<int> bytes) {
    final decoded = codec.decode(bytes);
    if (decoded is! Map) return null;
    if (decoded['id'] != null) return _responseFrom(decoded);
    final result = decoded['result'];
    if (result is Map && result['action'] != null) {
      final message = _liveMessage(result);
      if (message != null) return RpcNotification(message);
    }
    return null;
  }

  RpcResponse _responseFrom(Map<dynamic, dynamic> map) {
    final error = map['error'];
    if (error is Map) {
      return RpcResponse(
        id: map['id']?.toString() ?? '',
        error: ResponseError(
          error['message']?.toString() ?? 'RPC error',
          code: error['code'] is int ? error['code'] as int : null,
        ),
      );
    }
    return RpcResponse(id: map['id']?.toString() ?? '', result: map['result']);
  }

  LiveMessage? _liveMessage(Map<dynamic, dynamic> result) {
    final action = LiveAction.tryParse(result['action'].toString());
    if (action == null) return null;
    final queryId = _asUuid(result['id']);
    if (queryId == null) return null;
    final value = result['result'];
    RecordId? recordId;
    if (value is Map && value['id'] is RecordId) {
      recordId = value['id'] as RecordId;
    }
    return LiveMessage(
      queryId: queryId,
      action: action,
      value: value,
      recordId: recordId,
    );
  }

  static Uuid? _asUuid(Object? value) {
    if (value is Uuid) return value;
    if (value is String) return Uuid(value);
    return null;
  }
}
