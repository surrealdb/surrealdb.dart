/// A scope expression, in any of the ergonomic forms AgentMemory accepts.
///
/// Supported shapes:
/// - A single path string, for example `'team/eng'`.
/// - A list of path strings, treated as an OR of single path clauses.
/// - A list where each element is itself a list of paths, treated as an OR of
///   AND clauses.
///
/// Use [normaliseScope] to turn any of these into the disjunctive normal form
/// the server expects.
typedef Scope = Object?;

/// Normalises a [Scope] into disjunctive normal form: a list of OR clauses,
/// each being a list of AND paths.
///
/// Empty strings are dropped, paths within a clause are de duplicated keeping
/// first seen order, and empty clauses are removed. Returns null when nothing
/// remains, which tells the caller to omit the field.
List<List<String>>? normaliseScope(Scope scope) {
  if (scope == null) return null;

  final clauses = <List<String>>[];

  void addClause(List<String> raw) {
    final seen = <String>{};
    final clause = <String>[];
    for (final path in raw) {
      if (path.isEmpty) continue;
      if (seen.add(path)) clause.add(path);
    }
    if (clause.isNotEmpty) clauses.add(clause);
  }

  if (scope is String) {
    addClause([scope]);
  } else if (scope is List) {
    for (final element in scope) {
      if (element is String) {
        addClause([element]);
      } else if (element is List) {
        addClause(element.map((e) => e.toString()).toList());
      } else {
        throw ArgumentError(
            'A scope element must be a String or a List of Strings');
      }
    }
  } else {
    throw ArgumentError('A scope must be a String or a List');
  }

  return clauses.isEmpty ? null : clauses;
}
