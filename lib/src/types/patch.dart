/// A single JSON Patch operation, as accepted by the `patch` method.
sealed class Patch {
  const Patch();

  /// The operation in the wire form SurrealDB expects.
  Map<String, Object?> toJson();
}

/// Adds [value] at [path].
final class AddPatch extends Patch {
  const AddPatch(this.path, this.value);

  final String path;
  final Object? value;

  @override
  Map<String, Object?> toJson() => {'op': 'add', 'path': path, 'value': value};
}

/// Removes the value at [path].
final class RemovePatch extends Patch {
  const RemovePatch(this.path);

  final String path;

  @override
  Map<String, Object?> toJson() => {'op': 'remove', 'path': path};
}

/// Replaces the value at [path] with [value].
final class ReplacePatch extends Patch {
  const ReplacePatch(this.path, this.value);

  final String path;
  final Object? value;

  @override
  Map<String, Object?> toJson() =>
      {'op': 'replace', 'path': path, 'value': value};
}

/// Applies a string diff at [path]. This is a SurrealDB extension to JSON
/// Patch.
final class ChangePatch extends Patch {
  const ChangePatch(this.path, this.value);

  final String path;
  final String value;

  @override
  Map<String, Object?> toJson() =>
      {'op': 'change', 'path': path, 'value': value};
}

/// Copies the value at [from] to [path].
final class CopyPatch extends Patch {
  const CopyPatch({required this.path, required this.from});

  final String path;
  final String from;

  @override
  Map<String, Object?> toJson() => {'op': 'copy', 'path': path, 'from': from};
}

/// Moves the value at [from] to [path].
final class MovePatch extends Patch {
  const MovePatch({required this.path, required this.from});

  final String path;
  final String from;

  @override
  Map<String, Object?> toJson() => {'op': 'move', 'path': path, 'from': from};
}

/// Asserts that the value at [path] equals [value].
final class TestPatch extends Patch {
  const TestPatch(this.path, this.value);

  final String path;
  final Object? value;

  @override
  Map<String, Object?> toJson() => {'op': 'test', 'path': path, 'value': value};
}
