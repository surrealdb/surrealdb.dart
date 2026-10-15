import 'dart:convert';

/// Reads the expiry (`exp`) of a JWT without verifying it, or null when the
/// token is not a JWT or has no expiry.
DateTime? tokenExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final exp = payload is Map ? payload['exp'] : null;
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(),
        isUtc: true);
  } catch (_) {
    return null;
  }
}

/// How long to wait before renewing a token that expires at [expiry]:
/// [margin] before it expires, or half of the time left when that is shorter
/// than twice the margin, and never less than zero.
Duration renewalDelay(DateTime expiry, Duration margin, {DateTime? now}) {
  final remaining = expiry.difference(now ?? DateTime.now().toUtc());
  if (remaining <= Duration.zero) return Duration.zero;
  final early = remaining - margin;
  return early >= margin ? early : remaining ~/ 2;
}
