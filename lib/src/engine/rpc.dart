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
        error: ServerError.fromRpc(error),
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

/// Parses a record id in the string form the server writes in JSON, such as
/// `person:tobie`, `person:42`, `person:`a b``, `person:u'…'`,
/// `person:[1, 'a']` or `person:{ a: 1 }`. Returns null when the string is
/// not one this reader understands.
RecordId? parseRecordId(String value) {
  final reader = _SurqlReader(value);
  final id = reader.recordId();
  return reader.atEnd ? id : null;
}

/// Reads the SurrealQL values that can appear in a record id. Throws
/// [FormatException] on anything else.
class _SurqlReader {
  _SurqlReader(this._text);

  final String _text;
  var _i = 0;

  bool get atEnd {
    _skipSpace();
    return _i == _text.length;
  }

  RecordId? recordId() {
    try {
      final table = _ident();
      _expect(':');
      return RecordId(table, _id());
    } on FormatException {
      return null;
    }
  }

  Object _id() {
    final char = _peek();
    if (char == '[' || char == '{') return _value()!;
    if (char == 'u' && _isQuote(_peekAt(1))) return _value()!;
    final number = _integer.matchAsPrefix(_text, _i);
    if (number != null && !_isIdentChar(_peekAt(number.end - _i))) {
      _i = number.end;
      final digits = number.group(0)!;
      return int.tryParse(digits) ?? BigInt.parse(digits);
    }
    return _ident();
  }

  Object? _value() {
    _skipSpace();
    final char = _peek();
    switch (char) {
      case '[':
        _i++;
        final items = <Object?>[];
        while (true) {
          _skipSpace();
          if (_peek() == ']') break;
          items.add(_value());
          _skipSpace();
          if (_peek() != ',') break;
          _i++;
        }
        _expect(']');
        return items;
      case '{':
        _i++;
        final map = <String, Object?>{};
        while (true) {
          _skipSpace();
          if (_peek() == '}') break;
          final key = _isQuote(_peek()) ? _string() : _ident();
          _expect(':');
          map[key] = _value();
          _skipSpace();
          if (_peek() != ',') break;
          _i++;
        }
        _expect('}');
        return map;
      case "'":
      case '"':
        return _string();
    }
    if ((char == 'd' || char == 'u') && _isQuote(_peekAt(1))) {
      _i++;
      final text = _string();
      return char == 'd' ? SurrealDateTime.parse(text) : Uuid(text);
    }
    final duration = _duration.matchAsPrefix(_text, _i);
    if (duration != null) {
      _i = duration.end;
      return SurrealDuration.parse(duration.group(0)!);
    }
    final number = _number.matchAsPrefix(_text, _i);
    if (number != null) {
      _i = number.end;
      final digits = number.group(1)!;
      return switch (number.group(2)) {
        'dec' => Decimal(digits),
        'f' => double.parse(digits),
        _ when digits.contains(RegExp('[.eE]')) => double.parse(digits),
        _ => int.tryParse(digits) ?? BigInt.parse(digits),
      };
    }
    final start = _i;
    final word = _ident();
    switch (word) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'NULL':
        return null;
      case 'NONE':
        return null;
    }
    // A record id, such as `other:x`.
    _i = start;
    final nested = recordId();
    if (nested == null) throw FormatException('Unexpected value', _text, start);
    return nested;
  }

  String _string() {
    final quote = _peek();
    _i++;
    final buffer = StringBuffer();
    while (_i < _text.length) {
      final char = _text[_i];
      if (char == r'\' && _i + 1 < _text.length) {
        buffer.write(_text[_i + 1]);
        _i += 2;
      } else if (char == quote) {
        _i++;
        return buffer.toString();
      } else {
        buffer.write(char);
        _i++;
      }
    }
    throw FormatException('Unterminated string', _text, _i);
  }

  /// An identifier: plain, or escaped with backticks or angle brackets.
  String _ident() {
    _skipSpace();
    final open = _peek();
    if (open == '`' || open == '⟨') {
      final close = open == '`' ? '`' : '⟩';
      final buffer = StringBuffer();
      _i++;
      while (_i < _text.length) {
        final char = _text[_i];
        if (char == r'\' && _i + 1 < _text.length) {
          buffer.write(_text[_i + 1]);
          _i += 2;
        } else if (char == close) {
          _i++;
          return buffer.toString();
        } else {
          buffer.write(char);
          _i++;
        }
      }
      throw FormatException('Unterminated identifier', _text, _i);
    }
    final start = _i;
    while (_i < _text.length && _isIdentChar(_text[_i])) {
      _i++;
    }
    if (_i == start) throw FormatException('Expected a name', _text, _i);
    return _text.substring(start, _i);
  }

  void _expect(String char) {
    _skipSpace();
    if (_peek() != char) throw FormatException('Expected $char', _text, _i);
    _i++;
  }

  void _skipSpace() {
    while (_i < _text.length && _text[_i] == ' ') {
      _i++;
    }
  }

  String? _peek() => _peekAt(0);

  String? _peekAt(int offset) =>
      _i + offset < _text.length ? _text[_i + offset] : null;

  static bool _isQuote(String? char) => char == "'" || char == '"';

  static bool _isIdentChar(String? char) =>
      char != null && _identChar.hasMatch(char);

  static final _identChar = RegExp('[A-Za-z0-9_]');
  static final _integer = RegExp(r'-?\d+');
  static final _number = RegExp(r'(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)(dec|f)?');
  static final _duration =
      RegExp(r'(?:\d+(?:ns|µs|us|ms|s|m|h|d|w))+(?![A-Za-z0-9_])');
}
