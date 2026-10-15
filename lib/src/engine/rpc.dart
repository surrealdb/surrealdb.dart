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
    // The server sends the record id as `record`. In diff mode the result is
    // a list of patches with no `id`, so `record` is the only place it is.
    // Older servers only had it inside the result.
    RecordId? recordId;
    final record = result['record'];
    if (record is RecordId) {
      recordId = record;
    } else if (record is String) {
      // The JSON format sends it as a string.
      recordId = parseRecordId(record);
    } else if (value is Map && value['id'] is RecordId) {
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

/// A copy of [value] that later changes to the caller's maps, lists, sets
/// and byte buffers do not reach, so a value kept to send again later is the
/// value that was sent.
Object? snapshotValue(Object? value) => switch (value) {
      Uint8List() => Uint8List.fromList(value),
      Map() => <Object?, Object?>{
          for (final MapEntry(:key, :value) in value.entries)
            snapshotValue(key): snapshotValue(value),
        },
      List() => [for (final item in value) snapshotValue(item)],
      Set() => <Object?>{for (final item in value) snapshotValue(item)},
      _ => value,
    };

/// Parses a record id in the string form the server writes in JSON, such as
/// `person:tobie`, `person:42`, `person:`a b`` or `person:u'…'`. Returns
/// null for array and object ids, which need a SurrealQL parser.
RecordId? parseRecordId(String value) {
  final (table, rest) = _readIdent(value, 0);
  if (table == null || rest >= value.length || value[rest] != ':') {
    return null;
  }
  final id = value.substring(rest + 1);
  if (_integerId.hasMatch(id)) {
    return RecordId(table, int.tryParse(id) ?? BigInt.parse(id));
  }
  final uuid = _uuidId.firstMatch(id);
  if (uuid != null) {
    return RecordId(table, Uuid(uuid.group(1) ?? uuid.group(2)!));
  }
  final (name, end) = _readIdent(id, 0);
  if (name == null || end != id.length) return null;
  return RecordId(table, name);
}

final _integerId = RegExp(r'^-?\d+$');
final _uuidId = RegExp(r'''^u(?:'([0-9a-fA-F-]{36})'|"([0-9a-fA-F-]{36})")$''');
final _plainIdent = RegExp(r'[A-Za-z0-9_]');

/// Reads an identifier at [start]: plain, or escaped with backticks or
/// angle brackets. Returns it and the index after it.
(String?, int) _readIdent(String value, int start) {
  if (start >= value.length) return (null, start);
  final open = value[start];
  if (open == '`' || open == '⟨') {
    final close = open == '`' ? '`' : '⟩';
    final buffer = StringBuffer();
    var i = start + 1;
    while (i < value.length) {
      final char = value[i];
      if (char == r'\' && i + 1 < value.length) {
        buffer.write(value[i + 1]);
        i += 2;
      } else if (char == close) {
        return (buffer.toString(), i + 1);
      } else {
        buffer.write(char);
        i++;
      }
    }
    return (null, start);
  }
  var i = start;
  while (i < value.length && _plainIdent.hasMatch(value[i])) {
    i++;
  }
  return i == start ? (null, start) : (value.substring(start, i), i);
}
