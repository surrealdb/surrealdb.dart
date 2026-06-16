part of 'value.dart';

/// A pointer to a file in a SurrealDB bucket, for example `f"bucket:/path"`.
final class FileRef extends SurrealValue {
  const FileRef(this.bucket, this.key);

  final String bucket;
  final String key;

  @override
  Object toJson() => toString();

  @override
  String toString() => 'f"$bucket:$key"';

  @override
  bool operator ==(Object other) =>
      other is FileRef && other.bucket == bucket && other.key == key;

  @override
  int get hashCode => Object.hash(bucket, key);
}
