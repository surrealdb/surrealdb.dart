import 'package:surrealdb/surrealdb.dart';
import 'package:test/test.dart';

void main() {
  const cbor = CborCodec();
  const cbor2 = CborCodec(sizedNumbers: true);

  group('SizedInt', () {
    test('holds only its kind\'s range', () {
      expect(SizedInt.i8(-128).toInt(), -128);
      expect(() => SizedInt.i8(128), throwsRangeError);
      expect(() => SizedInt.u8(-1), throwsRangeError);
      final max = (BigInt.one << 64) - BigInt.one;
      expect(SizedInt(SizedKind.u64, max).value, max);
      expect(() => SizedInt(SizedKind.u64, max + BigInt.one), throwsRangeError);
      expect(() => SizedInt(SizedKind.f32, BigInt.one), throwsArgumentError);
    });

    test('equals only the same kind and value', () {
      expect(SizedInt.u8(5), SizedInt.u8(5));
      expect(SizedInt.u8(5), isNot(SizedInt.i8(5)));
      expect(SizedInt.u8(5), isNot(5));
      expect('${SizedInt.u8(5)}', '5u8');
    });
  });

  group('SizedFloat', () {
    test('holds only values its kind holds exactly', () {
      expect(SizedFloat.f16(65504).value, 65504);
      expect(SizedFloat.f32(0.10000000149011612).value, 0.10000000149011612);
      expect(() => SizedFloat.f16(0.1), throwsArgumentError);
      expect(() => SizedFloat.f32(0.1), throwsArgumentError);
      expect(SizedFloat.f16(double.nan).value.isNaN, isTrue);
    });

    test('finds the half-precision bits', () {
      expect(SizedFloat.halfBits(1), 0x3c00);
      expect(SizedFloat.halfBits(-2), 0xc000);
      expect(SizedFloat.halfBits(65504), 0x7bff);
      expect(SizedFloat.halfBits(5.960464477539063e-8), 0x0001);
      expect(SizedFloat.halfBits(-0.0), 0x8000);
      expect(SizedFloat.halfBits(65520), isNull);
      expect(SizedFloat.halfBits(0.1), isNull);
    });

    test('keeps -0 apart from 0', () {
      expect(SizedFloat.f32(-0.0), isNot(SizedFloat.f32(0)));
    });
  });

  group('over cbor.2', () {
    test('a sized number keeps its tag', () {
      expect(cbor2.encode(SizedInt.u8(5)), [0xd8, 0xb5, 0x05]);
      expect(cbor2.decode(cbor2.encode(SizedInt.i16(-3))), SizedInt.i16(-3));
      expect(
          cbor2.decode(cbor2.encode(SizedFloat.f32(1.5))), SizedFloat.f32(1.5));
    });

    test('names the dialect', () {
      expect(cbor2.name, 'cbor.2');
      expect(cbor2.contentType, 'application/cbor; v=2');
      expect(cbor.name, 'cbor');
      expect(cbor.contentType, 'application/cbor');
      expect(cbor.copyWith(sizedNumbers: true).name, 'cbor.2');
    });
  });

  group('over plain cbor', () {
    test('a sized number is widened', () {
      expect(cbor.encode(SizedInt.u8(5)), [0x05]);
      expect(cbor.decode(cbor.encode(SizedFloat.f32(1.5))), 1.5);
      final big = (BigInt.one << 64) - BigInt.one;
      expect(cbor.decode(cbor.encode(SizedInt(SizedKind.u64, big))),
          Decimal('$big'));
    });

    test('the sized-number tags are refused', () {
      expect(() => cbor.decode([0xd8, 0xb5, 0x05]), throwsFormatException);
    });
  });
}
