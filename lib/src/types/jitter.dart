import 'dart:math';

final Random _random = Random();

/// A random number in `[-1, 1)`, used to vary reconnect delays.
double randomJitterFactor() => _random.nextDouble() * 2 - 1;
