import '../cbor/codec.dart';
import '../json/codec.dart';
import 'codec.dart';

/// Returns the built in codec for the given [format].
SurrealCodec codecForFormat(SurrealFormat format) => switch (format) {
      SurrealFormat.cbor => const CborCodec(),
      SurrealFormat.json => const JsonCodec(),
    };
