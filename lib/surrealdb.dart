/// A Dart and Flutter client for SurrealDB.
///
/// The entry point is the [Surreal] class. Connect to a server, select a
/// namespace and database with `use`, authenticate, then run queries, CRUD
/// operations, and live queries.
library;

export 'src/cbor/codec.dart' show CborCodec;
export 'src/cbor/tags.dart' show SurrealCborTags;
export 'src/errors.dart';
export 'src/live_query.dart' show LiveQuery;
export 'src/protocol/codec.dart' show SurrealCodec, SurrealFormat;
export 'src/surreal.dart' show Surreal;
export 'src/types/auth.dart';
export 'src/types/connection.dart';
export 'src/types/live.dart';
export 'src/types/patch.dart';
export 'src/value/value.dart';
