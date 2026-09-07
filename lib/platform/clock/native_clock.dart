import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/domain.dart';

/// Samples the native sleep-inclusive clock on every call, including after a
/// suspension or process restart. Never extrapolates a cached wall/uptime pair.
final class NativeClock implements Clock {
  const NativeClock({
    this.channel = const MethodChannel('io.github.vanzeph.minutrove/clock'),
    this.timeout = const Duration(seconds: 2),
  });

  final MethodChannel channel;
  final Duration timeout;

  @override
  Future<ClockReading> now() async {
    try {
      final value = await channel
          .invokeMapMethod<String, Object?>('now')
          .timeout(timeout);
      if (value == null ||
          value['utcMilliseconds'] is! int ||
          value['monotonicMilliseconds'] is! int ||
          value['bootId'] is! String ||
          (value['bootId'] as String).length > 128) {
        throw const FormatException('Invalid native clock sample');
      }
      return ClockReading(
        utc: DateTime.fromMillisecondsSinceEpoch(
          value['utcMilliseconds'] as int,
          isUtc: true,
        ),
        bootId: value['bootId'] as String,
        monotonic: Milliseconds(value['monotonicMilliseconds'] as int),
      );
    } catch (_) {
      // Do not disclose platform exception details or commit with wall time
      // alone when a reliable same-boot sample cannot be obtained.
      throw const StorageUnavailable(retryable: true);
    }
  }
}
