import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/notifications/android_notifications.dart';

SessionId _session(String suffix) =>
    SessionId('00000000-0000-0000-0000-0000000000$suffix');
CompletionId _completion(String suffix) =>
    CompletionId('00000000-0000-0000-0001-0000000000$suffix');
OperationId get _operation =>
    OperationId('00000000-0000-0000-0002-000000000099');

NotificationIntent _intent({
  required String suffix,
  Revision? revision,
  DateTime? deadline,
  bool handled = false,
}) => NotificationIntent(
  sessionId: _session(suffix),
  sessionRevision: revision ?? Revision(1),
  completionId: _completion(suffix),
  deadlineUtc: deadline,
  completionChimeHandled: handled,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scheduler = AndroidNotificationScheduler(
    timeout: Duration(milliseconds: 20),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(scheduler.channel, null));

  test('maps every native permission state exactly', () async {
    for (final entry in {
      'granted': NotificationPermission.granted,
      'denied': NotificationPermission.denied,
      'notDetermined': NotificationPermission.notDetermined,
      'restricted': NotificationPermission.restricted,
    }.entries) {
      messenger.setMockMethodCallHandler(
        scheduler.channel,
        (_) async => entry.key,
      );
      expect(await scheduler.permission(), entry.value);
    }
  });

  for (final bad in [null, 7, 'unknown-state']) {
    test('invalid permission payload is a retryable error: $bad', () async {
      messenger.setMockMethodCallHandler(scheduler.channel, (_) async => bad);
      await expectLater(
        scheduler.permission(),
        throwsA(
          isA<StorageUnavailable>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });
  }

  test('native failures never invent a permission state', () async {
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      throw PlatformException(code: 'private-platform-details');
    });
    await expectLater(
      scheduler.permission(),
      throwsA(isA<StorageUnavailable>()),
    );
  });

  test('requestPermission forwards the operation id for idempotency', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(scheduler.channel, (call) async {
      calls.add(call);
      return 'granted';
    });
    expect(
      await scheduler.requestPermission(operationId: _operation),
      NotificationPermission.granted,
    );
    expect(calls.single.method, 'requestPermission');
    expect(calls.single.arguments, {'operationId': _operation.value});
  });

  test(
    'requestPermission failure is retryable without a fabricated state',
    () async {
      messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
        throw PlatformException(code: 'invalid_operation_id');
      });
      await expectLater(
        scheduler.requestPermission(operationId: _operation),
        throwsA(isA<StorageUnavailable>()),
      );
    },
  );

  test('reconcile serializes persisted intents exactly once each', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(scheduler.channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'permission': 'granted',
        'delivered': <Object>[_completion('01').value],
      };
    });
    final result = await scheduler.reconcileDetailed(
      operationId: _operation,
      intents: [
        _intent(suffix: '01', deadline: DateTime.utc(2026, 9, 14, 12)),
        _intent(suffix: '02', handled: true),
      ],
    );
    expect(calls.single.method, 'reconcile');
    expect(calls.single.arguments, {
      'operationId': _operation.value,
      'intents': [
        {
          'sessionId': _session('01').value,
          'sessionRevision': 1,
          'completionId': _completion('01').value,
          'deadlineUtcMilliseconds': DateTime.utc(
            2026,
            9,
            14,
            12,
          ).millisecondsSinceEpoch,
          'handled': false,
        },
        {
          'sessionId': _session('02').value,
          'sessionRevision': 1,
          'completionId': _completion('02').value,
          'deadlineUtcMilliseconds': null,
          'handled': true,
        },
      ],
    });
    final value = (result as Success<NotificationReconciliation>).value;
    expect(value.permission, NotificationPermission.granted);
    expect(value.delivered, {_completion('01')});

    // The port view reports the permission without losing the error channel.
    final portView = await scheduler.reconcile(
      operationId: _operation,
      intents: const [],
    );
    expect(
      (portView as Success<NotificationPermission>).value,
      NotificationPermission.granted,
    );
  });

  for (final bad in [
    <String, Object?>{'permission': 'granted', 'delivered': 'no-list'},
    <String, Object?>{
      'permission': 'granted',
      'delivered': <Object>['not-a-uuid'],
    },
    <String, Object?>{'permission': 'granted'},
    <String, Object?>{'permission': 'maybe', 'delivered': <Object>[]},
  ]) {
    test('malformed reconcile payload fails retryable: $bad', () async {
      messenger.setMockMethodCallHandler(scheduler.channel, (_) async => bad);
      final result = await scheduler.reconcileDetailed(
        operationId: _operation,
        intents: const [],
      );
      expect(
        result,
        isA<Failure<NotificationReconciliation>>().having(
          (f) => f.error,
          'error',
          isA<StorageUnavailable>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });
  }

  test('native reconcile failure keeps the last converged OS state', () async {
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      throw PlatformException(code: 'reconcile_failed');
    });
    expect(
      await scheduler.reconcile(operationId: _operation, intents: const []),
      isA<Failure<NotificationPermission>>().having(
        (f) => f.error,
        'error',
        isA<StorageUnavailable>(),
      ),
    );
  });

  test('a hung native reconcile times out retryably', () async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(
      scheduler.channel,
      (_) => pending.future,
    );
    final result = await scheduler.reconcileDetailed(
      operationId: _operation,
      intents: const [],
    );
    expect(
      result,
      isA<Failure<NotificationReconciliation>>().having(
        (f) => f.error,
        'error',
        isA<StorageUnavailable>(),
      ),
    );
    pending.complete(null);
  });

  test('openSystemSettings reports the native outcome only', () async {
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async => true);
    expect(
      await scheduler.openSystemSettings(operationId: _operation),
      isA<Success<bool>>().having((s) => s.value, 'value', isTrue),
    );
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      throw PlatformException(code: 'activity-not-found');
    });
    expect(
      await scheduler.openSystemSettings(operationId: _operation),
      isA<Failure<bool>>(),
    );
  });

  test('consumeLaunchCompletion reports each tap exactly once', () async {
    var queued = <String?>[
      '00000000-0000-0000-0003-0000000000aa',
      null,
      'garbage',
    ];
    messenger.setMockMethodCallHandler(
      scheduler.channel,
      (_) async => queued.removeAt(0),
    );
    expect(
      await scheduler.consumeLaunchCompletion(),
      CompletionId('00000000-0000-0000-0003-0000000000aa'),
    );
    expect(await scheduler.consumeLaunchCompletion(), isNull);
    expect(await scheduler.consumeLaunchCompletion(), isNull);
    expect(queued, isEmpty);
  });

  test(
    'a failed launch-completion probe never surfaces a storage error',
    () async {
      messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
        throw PlatformException(code: 'channel-down');
      });
      expect(await scheduler.consumeLaunchCompletion(), isNull);
    },
  );
}
