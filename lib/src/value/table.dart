part of 'value.dart';

/// A reference to a table by name, for example `person`.
///
/// Passing a [Table] to methods such as `select` or `create` targets every
/// record in the table, as opposed to a single [RecordId].
final class Table extends SurrealValue {
  const Table(this.name);

  final String name;

  @override
  Object toJson() => name;

  @override
  String toString() => _escapeIdent(name);

  @override
  bool operator ==(Object other) => other is Table && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

final RegExp _simpleIdent = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Escapes an identifier for use in a SurrealQL string. Simple identifiers are
/// returned unchanged, anything else is wrapped in backticks.
String _escapeIdent(String value) {
  if (_simpleIdent.hasMatch(value)) return value;
  final escaped = value.replaceAll('`', r'\`');
  return '`$escaped`';
}
