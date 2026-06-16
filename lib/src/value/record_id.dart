part of 'value.dart';

/// A record identifier, made of a table name and an id, for example
/// `person:tobie`.
///
/// The id may be a [String], [int], [BigInt], [Uuid], [List] or [Map]. Use
/// [StringRecordId] when you already hold a formatted `table:id` string and do
/// not want it parsed.
final class RecordId extends SurrealValue {
  const RecordId(this.table, this.id);

  final String table;
  final Object id;

  @override
  Object toJson() => toString();

  @override
  String toString() => '${_escapeIdent(table)}:${_formatId(id)}';

  @override
  bool operator ==(Object other) =>
      other is RecordId && other.table == table && _idEquals(other.id, id);

  @override
  int get hashCode => Object.hash(table, _idHash(id));
}

/// A record id that wraps an already formatted `table:id` string. The string is
/// sent to the server verbatim and is not parsed on the client.
final class StringRecordId extends SurrealValue {
  const StringRecordId(this.value);

  final String value;

  @override
  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is StringRecordId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A range of record ids within a table, for example `person:1..=100`.
final class RecordIdRange extends SurrealValue {
  const RecordIdRange(this.table, {this.begin, this.end});

  final String table;
  final Bound? begin;
  final Bound? end;

  @override
  Object toJson() => toString();

  @override
  String toString() {
    final start = switch (begin) {
      null => '',
      BoundIncluded(:final value) => _formatId(value),
      BoundExcluded(:final value) => _formatId(value),
    };
    final op = begin is BoundExcluded ? '>' : '';
    final endOp = end is BoundIncluded ? '=' : '';
    final stop = switch (end) {
      null => '',
      BoundIncluded(:final value) => _formatId(value),
      BoundExcluded(:final value) => _formatId(value),
    };
    return '${_escapeIdent(table)}:$op$start..$endOp$stop';
  }

  @override
  bool operator ==(Object other) =>
      other is RecordIdRange &&
      other.table == table &&
      other.begin == begin &&
      other.end == end;

  @override
  int get hashCode => Object.hash(table, begin, end);
}

String _formatId(Object? id) {
  return switch (id) {
    null => 'NULL',
    int() => id.toString(),
    BigInt() => id.toString(),
    String() =>
      _simpleIdent.hasMatch(id) ? id : '`${id.replaceAll('`', r'\`')}`',
    Uuid() => 'u"$id"',
    _ => id.toString(),
  };
}

bool _idEquals(Object a, Object b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
  return a == b;
}

int _idHash(Object id) => id is List ? Object.hashAll(id) : id.hashCode;
