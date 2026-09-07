import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/clock/native_clock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const clock = NativeClock(timeout: Duration(milliseconds: 20));
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(clock.channel, null));

  test('every await uses a fresh native sample, including across adapter instances', () async {
    var count = 0;
    messenger.setMockMethodCallHandler(clock.channel, (call) async {
      expect(call.method, 'now');
      await Future<void>.delayed(Duration.zero);
      count++;
      return {
        'utcMilliseconds': DateTime.utc(2026).millisecondsSinceEpoch + count,
        'monotonicMilliseconds': 1000 + count,
        'bootId': 'synthetic-stable-boot',
      };
    });
    final first = await clock.now();
    final second = await const NativeClock().now();
    expect(first.bootId, second.bootId);
    expect(second.monotonic.value - first.monotonic.value, 1);
    expect(second.utc.difference(first.utc).inMilliseconds, 1);
  });

  for (final bad in [
    null,
    <String, Object?>{},
    {'utcMilliseconds': 1, 'monotonicMilliseconds': -1, 'bootId': 'boot'},
    {'utcMilliseconds': 1, 'monotonicMilliseconds': 1.5, 'bootId': 'boot'},
    {'utcMilliseconds': 1, 'monotonicMilliseconds': 1, 'bootId': ''},
    {
      'utcMilliseconds': 8640000000000001,
      'monotonicMilliseconds': 1,
      'bootId': 'boot',
    },
  ]) {
    test(
      'invalid native sample returns a retryable, sanitized error: $bad',
      () async {
        messenger.setMockMethodCallHandler(clock.channel, (_) async => bad);
        await expectLater(
          clock.now(),
          throwsA(
            isA<StorageUnavailable>().having(
              (e) => e.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
      },
    );
  }

  test(
    'platform failure and timeout cannot substitute a stale sample',
    () async {
      messenger.setMockMethodCallHandler(clock.channel, (_) async {
        throw PlatformException(code: 'private-platform-details');
      });
      await expectLater(clock.now(), throwsA(isA<StorageUnavailable>()));
      final pending = Completer<Map<String, Object?>>();
      messenger.setMockMethodCallHandler(clock.channel, (_) => pending.future);
      await expectLater(clock.now(), throwsA(isA<StorageUnavailable>()));
      pending.complete({});
    },
  );
}
