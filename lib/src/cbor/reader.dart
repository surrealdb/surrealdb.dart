import 'dart:convert';
import 'dart:typed_data';

/// Builds a Dart value from a CBOR tag number and the already decoded value it
/// wraps.
typedef CborTagHandler = Object? Function(int tag, Object? value);

/// A small CBOR decoder that keeps every tag.
///
/// The `cbor` package drops the tags of integers while decoding, so a value
/// such as an exclusive range bound (`51(5)`) arrives as a bare `5`. This
/// reader decodes straight to Dart values and hands every tag, with the value
/// it wraps, to a [CborTagHandler].
///
/// Integers that do not fit in a Dart `int` on the current platform become a
/// [BigInt]. On the web that means anything outside the 53-bit safe range.
class CborReader {
  CborReader(List<int> bytes, this._onTag)
      : _bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes) {
    _data = ByteData.sublistView(_bytes);
  }

  final Uint8List _bytes;
  late final ByteData _data;
  final CborTagHandler _onTag;
  var _offset = 0;

  static const int _breakByte = 0xff;
  static const int _indefinite = -1;

  /// Decodes a single CBOR item, failing if bytes are left over.
  Object? readAll() {
    final value = _readItem();
    if (_offset != _bytes.length) {
      throw FormatException('Unexpected trailing CBOR data', _bytes, _offset);
    }
    return value;
  }

  Object? _readItem() {
    final initial = _readByte();
    final major = initial >> 5;
    final info = initial & 0x1f;
    switch (major) {
      case 0:
        return _readArgument(info);
      case 1:
        final n = _readArgument(info);
        return n is int ? -1 - n : _normalise(-BigInt.one - (n as BigInt));
      case 2:
        return _readBytes(info);
      case 3:
        return utf8.decode(_readBytes(info));
      case 4:
        final length = _readLength(info);
        final list = <Object?>[];
        if (length == _indefinite) {
          while (!_atBreak()) {
            list.add(_readItem());
          }
        } else {
          for (var i = 0; i < length; i++) {
            list.add(_readItem());
          }
        }
        return list;
      case 5:
        final length = _readLength(info);
        final map = <String, dynamic>{};
        void entry() {
          final key = _readItem();
          map[key is String ? key : key.toString()] = _readItem();
        }

        if (length == _indefinite) {
          while (!_atBreak()) {
            entry();
          }
        } else {
          for (var i = 0; i < length; i++) {
            entry();
          }
        }
        return map;
      case 6:
        final tag = _readArgument(info);
        if (tag is! int) {
          throw FormatException('CBOR tag out of range', _bytes, _offset);
        }
        return _onTag(tag, _readItem());
      default:
        return _readSimple(info);
    }
  }

  Object? _readSimple(int info) {
    switch (info) {
      case 20:
        return false;
      case 21:
        return true;
      case 22:
      case 23:
        return null;
      case 25:
        return _halfToDouble(_readUint(2));
      case 26:
        final value = _data.getFloat32(_offset);
        _offset += 4;
        return value;
      case 27:
        final value = _data.getFloat64(_offset);
        _offset += 8;
        return value;
      default:
        throw FormatException(
            'Unsupported CBOR simple value $info', _bytes, _offset);
    }
  }

  bool _atBreak() {
    if (_bytes[_offset] == _breakByte) {
      _offset++;
      return true;
    }
    return false;
  }

  Uint8List _readBytes(int info) {
    final length = _readLength(info);
    if (length != _indefinite) {
      _ensure(length);
      final bytes = Uint8List.sublistView(_bytes, _offset, _offset + length);
      _offset += length;
      return Uint8List.fromList(bytes);
    }
    // An indefinite length string is a sequence of definite length chunks.
    final builder = BytesBuilder(copy: false);
    while (!_atBreak()) {
      final chunk = _readByte();
      builder.add(_readBytes(chunk & 0x1f));
    }
    return builder.takeBytes();
  }

  int _readLength(int info) {
    if (info == 31) return _indefinite;
    final length = _readArgument(info);
    if (length is! int) {
      throw FormatException('CBOR length out of range', _bytes, _offset);
    }
    return length;
  }

  /// Reads the argument that follows an initial byte: a small value packed
  /// into [info], or 1, 2, 4 or 8 following bytes.
  Object _readArgument(int info) {
    if (info < 24) return info;
    switch (info) {
      case 24:
        return _readUint(1);
      case 25:
        return _readUint(2);
      case 26:
        return _readUint(4);
      case 27:
        final high = _readUint(4);
        final low = _readUint(4);
        // Below 2^53 the value is exact as an int on every platform.
        if (high < 0x200000) return high * 0x100000000 + low;
        return _normalise((BigInt.from(high) << 32) | BigInt.from(low));
      default:
        throw FormatException(
            'Unsupported CBOR additional info $info', _bytes, _offset);
    }
  }

  int _readUint(int size) {
    _ensure(size);
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = value * 256 + _bytes[_offset + i];
    }
    _offset += size;
    return value;
  }

  int _readByte() {
    _ensure(1);
    return _bytes[_offset++];
  }

  void _ensure(int count) {
    if (_offset + count > _bytes.length) {
      throw FormatException('Unexpected end of CBOR data', _bytes, _offset);
    }
  }

  /// Returns [value] as an `int` when it fits, otherwise as is.
  static Object _normalise(BigInt value) =>
      value.isValidInt ? value.toInt() : value;

  static double _halfToDouble(int half) {
    final sign = (half & 0x8000) != 0 ? -1.0 : 1.0;
    final exponent = (half >> 10) & 0x1f;
    final mantissa = half & 0x3ff;
    if (exponent == 0) return sign * mantissa * _pow2(-24);
    if (exponent == 0x1f) {
      return mantissa == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1 + mantissa / 1024) * _pow2(exponent - 15);
  }

  static double _pow2(int exponent) {
    var result = 1.0;
    final factor = exponent < 0 ? 0.5 : 2.0;
    for (var i = 0; i < exponent.abs(); i++) {
      result *= factor;
    }
    return result;
  }
}
