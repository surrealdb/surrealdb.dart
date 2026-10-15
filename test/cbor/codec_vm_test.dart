@TestOn('vm')
library;

import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

/// Integer cases that only hold where `int` is 64 bits wide.
void main() {
  const codec = CborCodec();

  test('64-bit integers decode to int on the VM', () {
    // 0x1b 7fffffffffffffff
    expect(
      codec.decode([0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
      9223372036854775807,
    );
    // 0x3b 7fffffffffffffff is -2^63
    expect(
      codec.decode([0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
      -9223372036854775808,
    );
  });
}
