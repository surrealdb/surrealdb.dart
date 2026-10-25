/// Runs the shared CBOR test vectors from surrealdb-protocol (the release in
/// `test/conformance/VERSION`) through the codec: `cbor.yaml` over plain
/// `cbor` and over `cbor.2`, and `cbor2.yaml` over `cbor.2`.
///
/// The vectors are not committed here. Fetch them first with
/// `tool/fetch_conformance_vectors.sh`; without them these tests are skipped,
/// except in CI, where they fail.
@TestOn('vm')
library;

import 'dart:io';

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'typed_json.dart';

/// Vectors this SDK cannot pass, with the reason.
const _knownGaps = {
  'duration-u64-seconds': 'SurrealDuration holds its seconds in an int, '
      'which stops at 2^63 - 1, so a duration of u64::MAX seconds is refused',
};

void main() {
  const cbor = CborCodec();
  const cbor2 = CborCodec(sizedNumbers: true);

  if (!File('$_dir/cbor.yaml').existsSync()) {
    const reason =
        'The vectors are missing: run tool/fetch_conformance_vectors.sh';
    if (Platform.environment['CI'] == 'true') {
      test('shared CBOR vectors', () => fail(reason));
    } else {
      test('shared CBOR vectors', () {}, skip: reason);
    }
    return;
  }

  final plain = _load('cbor.yaml');
  final sized = _load('cbor2.yaml');

  group('cbor.yaml over cbor', () {
    for (final vector in plain) {
      if (_formats(vector).contains('cbor')) _check(vector, cbor);
    }
  });

  group('cbor.yaml over cbor.2', () {
    for (final vector in plain) {
      if (_formats(vector).contains('cbor.2')) _check(vector, cbor2);
    }
  });

  group('cbor2.yaml over cbor.2', () {
    for (final vector in sized) {
      if (_formats(vector).contains('cbor.2')) _check(vector, cbor2);
    }
  });
}

const _dir = 'test/conformance/vectors';

List<Map<Object?, Object?>> _load(String name) {
  final file = File('$_dir/$name');
  final doc = loadYaml(file.readAsStringSync()) as Map<Object?, Object?>;
  return (doc['vectors'] as List).cast<Map<Object?, Object?>>();
}

/// The dialects a vector holds for: all of them unless it says otherwise.
List<String> _formats(Map<Object?, Object?> vector) =>
    (vector['formats'] as List?)?.cast<String>() ?? const ['cbor', 'cbor.2'];

void _check(Map<Object?, Object?> vector, CborCodec codec) {
  final name = vector['name'] as String;
  final bytes = _hex(vector['cbor'] as String);
  test(name, skip: _knownGaps[name], () {
    switch (vector['kind']) {
      case 'canonical':
        final value = fromTyped(vector['value']);
        _expectSame(codec.decode(bytes), value, 'decoding');
        _expectSame(codec.decode(codec.encode(value)), value, 'round trip');
      case 'decode':
        _expectSame(
            codec.decode(bytes), fromTyped(vector['value']), 'decoding');
      case 'reject':
        expect(() => codec.decode(bytes), throwsFormatException);
      default:
        fail('Unknown kind ${vector['kind']}');
    }
  });
}

void _expectSame(Object? actual, Object? expected, String what) {
  if (!sameValue(actual, expected)) {
    fail('$what gave ${toTyped(actual)}, expected ${toTyped(expected)}');
  }
}

List<int> _hex(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
