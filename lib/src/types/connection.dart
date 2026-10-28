import '../protocol/codec.dart';
import 'auth.dart';
import 'jitter.dart';

/// The lifecycle states a connection moves through.
enum ConnectionStatus {
  disconnected,
  connecting,
  reconnecting,
  connected,
}

/// Controls how the WebSocket engine reconnects after a dropped connection.
class ReconnectOptions {
  const ReconnectOptions({
    this.enabled = true,
    this.attempts = 5,
    this.retryDelay = const Duration(seconds: 1),
    this.retryDelayMax = const Duration(seconds: 60),
    this.retryDelayMultiplier = 2.0,
    this.retryDelayJitter = 0.1,
  });

  /// Disables automatic reconnection.
  static const ReconnectOptions disabled = ReconnectOptions(enabled: false);

  /// Whether reconnection is attempted at all.
  final bool enabled;

  /// The maximum number of attempts before giving up. A negative value means
  /// retry without limit.
  final int attempts;

  /// The base delay. Attempt `n` waits `retryDelay * multiplier^n`, so the
  /// first retry already waits `retryDelay * multiplier`, as in the
  /// JavaScript SDK.
  final Duration retryDelay;

  /// The cap applied to the growing retry delay.
  final Duration retryDelayMax;

  /// The factor the delay is multiplied by after each failed attempt.
  final double retryDelayMultiplier;

  /// The fraction by which each delay is randomly varied, up or down, so
  /// clients that lost the same server do not all retry together.
  final double retryDelayJitter;

  /// The delay to wait before the given attempt, starting at attempt 1:
  /// `min(retryDelay * multiplier^attempt * (1 + jitter), retryDelayMax)`,
  /// where jitter is random in `[-retryDelayJitter, retryDelayJitter]`. This
  /// is the schedule the JavaScript SDK uses.
  ///
  /// [random] stands in for the source of randomness, a number in `[-1, 1)`.
  Duration delayForAttempt(int attempt, {double Function()? random}) {
    final jitter = retryDelayJitter == 0
        ? 0.0
        : (random ?? randomJitterFactor)() * retryDelayJitter;
    final scaled = retryDelay.inMilliseconds *
        _pow(retryDelayMultiplier, attempt) *
        (1 + jitter);
    final capped = scaled.clamp(0, retryDelayMax.inMilliseconds.toDouble());
    return Duration(milliseconds: capped.round());
  }

  static double _pow(double base, int exponent) {
    var result = 1.0;
    for (var i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }
}

/// Options passed to `connect`.
class ConnectOptions {
  const ConnectOptions({
    this.namespace,
    this.database,
    this.authentication,
    this.token,
    this.reconnect = const ReconnectOptions(),
    this.versionCheck = true,
    this.timeout = const Duration(seconds: 30),
    this.format = SurrealFormat.cbor,
    this.codec,
  });

  /// The namespace to select once connected.
  final String? namespace;

  /// The database to select once connected.
  final String? database;

  /// Credentials to sign in with once connected.
  final AnyAuth? authentication;

  /// An existing token to authenticate with once connected.
  final String? token;

  /// How to behave when the connection drops.
  final ReconnectOptions reconnect;

  /// Whether to check the server version after connecting.
  final bool versionCheck;

  /// How long to wait for the connection to be established.
  final Duration timeout;

  /// The serialization format. Defaults to CBOR, which carries the SurrealDB
  /// types without loss. Ignored when [codec] is set.
  final SurrealFormat format;

  /// A custom codec. When set, it overrides [format].
  final SurrealCodec? codec;
}
