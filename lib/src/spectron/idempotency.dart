import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The width of the idempotency bucket, in seconds. Requests made within the
/// same bucket with the same method, path, and body share a key.
const int idempotencyBucketSeconds = 30;

/// Derives the value for the `Idempotency-Key` header.
///
/// The key is the hex SHA-256 of the method, path, body, and a time bucket
/// joined by null bytes. The time bucket means two identical requests sent
/// close together share a key, so the server can treat them as one.
String idempotencyKey(
  String method,
  String path,
  String body, {
  DateTime? now,
}) {
  final separator = String.fromCharCode(0);
  final millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final bucket = millis ~/ 1000 ~/ idempotencyBucketSeconds;
  final input = [method, path, body, '$bucket'].join(separator);
  return sha256.convert(utf8.encode(input)).toString();
}
