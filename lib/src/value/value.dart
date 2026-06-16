import 'dart:typed_data';

import 'package:uuid/parsing.dart' as uuidlib;
import 'package:uuid/uuid.dart' as uuidlib;

part 'record_id.dart';
part 'table.dart';
part 'range.dart';
part 'uuid.dart';
part 'decimal.dart';
part 'duration.dart';
part 'datetime.dart';
part 'future.dart';
part 'file_ref.dart';
part 'geometry.dart';

/// Base type for every value that has a dedicated SurrealDB representation on
/// the wire. These types round trip through the CBOR codec without loss.
///
/// The hierarchy is sealed so the codec can switch over it exhaustively.
sealed class SurrealValue {
  const SurrealValue();

  /// A JSON friendly representation of this value. Used for logging and for
  /// the fallback JSON protocol. It is not the CBOR wire form.
  Object? toJson();
}
