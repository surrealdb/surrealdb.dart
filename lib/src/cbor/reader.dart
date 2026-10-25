import 'dart:convert';
import 'dart:typed_data';

/// [value] as an [int] when an `int` holds it exactly on this platform, and
/// as is otherwise. On the web that means within 53 bits; `isValidInt` is no
/// test there, as it accepts integers a JavaScript number only rounds to.
Object exactInt(BigInt value) =>
    value.bitLength <= (_web ? 53 : 63) ? value.toInt() : value;

const _web = identical(0, 0.0);

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
///
/// It decodes as strictly as SurrealDB does: an integer outside the 64-bit
/// signed range (except as a `u64`, tag 186), a map key that is not a string
/// or that repeats, and an indefinite-length string whose chunks are of
/// another type or split a UTF-8 sequence are all errors.
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

  static final _i64Max = (BigInt.one << 63) - BigInt.one;

  /// The tags of SurrealDB's sized numbers: integers (180 to 186), then
  /// floats (187 and 188).
  static const int _firstSizedInt = 180;
  static const int _u64 = 186;
  static const int _lastSizedFloat = 188;

  /// Whether the next item may be an integer beyond the 64-bit signed range,
  /// which only a `u64` may be.
  var _wide = false;

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
    final wide = _wide;
    _wide = false;
    switch (major) {
      case 0:
        final n = _readArgument(info);
        if (!wide && n is BigInt && n > _i64Max) {
          throw FormatException(
              'Integer $n is outside the 64-bit signed range', _bytes, _offset);
        }
        return n;
      case 1:
        final n = _readArgument(info);
        if (n is int) return -1 - n;
        final value = -BigInt.one - (n as BigInt);
        if (n > _i64Max) {
          throw FormatException(
              'Integer $value is outside the 64-bit signed '
              'range',
              _bytes,
              _offset);
        }
        return _normalise(value);
      case 2:
        return _readBytes(info);
      case 3:
        return _readText(info);
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
          if (key is! String) {
            throw FormatException(
                'A CBOR map key must be a string, not $key', _bytes, _offset);
          }
          if (map.containsKey(key)) {
            throw FormatException(
                'Duplicate key $key in a CBOR map', _bytes, _offset);
          }
          map[key] = _readItem();
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
        if (tag >= _firstSizedInt && tag <= _lastSizedFloat) {
          _checkSized(tag);
          _wide = tag == _u64;
        }
        return _onTag(tag, _readItem());
      default:
        return _readSimple(info);
    }
  }

  /// Checks that a sized number holds the right type of item: an integer
  /// under an integer kind, a float under a float kind.
  void _checkSized(int tag) {
    _ensure(1);
    final initial = _bytes[_offset];
    final major = initial >> 5;
    final info = initial & 0x1f;
    final ok = tag <= _u64
        ? major == 0 || major == 1
        : major == 7 && info >= 25 && info <= 27;
    if (!ok) {
      throw FormatException(
          'CBOR tag $tag holds the wrong type of item', _bytes, _offset);
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
    _ensure(1);
    if (_bytes[_offset] == _breakByte) {
      _offset++;
      return true;
    }
    return false;
  }

  Uint8List _readBytes(int info) {
    final length = _readLength(info);
    if (length != _indefinite) return _readDefinite(length);
    // An indefinite length string is a sequence of definite length chunks of
    // the same type.
    final builder = BytesBuilder(copy: false);
    while (!_atBreak()) {
      builder.add(_readDefinite(_readChunkLength(2)));
    }
    return builder.takeBytes();
  }

  String _readText(int info) {
    final length = _readLength(info);
    if (length != _indefinite) return utf8.decode(_readDefinite(length));
    // Each chunk must be valid UTF-8 on its own.
    final text = StringBuffer();
    while (!_atBreak()) {
      text.write(utf8.decode(_readDefinite(_readChunkLength(3))));
    }
    return text.toString();
  }

  /// Reads the head of a chunk of an indefinite length string of [major] type.
  int _readChunkLength(int major) {
    final initial = _readByte();
    final info = initial & 0x1f;
    if (initial >> 5 != major || info == 31) {
      throw FormatException(
          'Wrong chunk in an indefinite length string', _bytes, _offset);
    }
    return _readLength(info);
  }

  Uint8List _readDefinite(int length) {
    _ensure(length);
    final bytes = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(bytes);
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

  static Object _normalise(BigInt value) => exactInt(value);

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
