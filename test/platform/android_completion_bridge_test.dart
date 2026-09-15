import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app_startup.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/notifications/android_notifications.dart';
import 'package:minutrove/platform/notifications/notification_taps.dart';

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

  test('a delivered completion owns the cue until acknowledged', () async {
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      return <String, Object?>{
        'permission': 'granted',
        'delivered': <Object>[_completion('01').value],
      };
    });
    final bridge = AndroidCompletionBridge(scheduler);
    final result = await bridge.reconcile(
      operationId: _operation,
      intents: [_intent(suffix: '01', deadline: DateTime.utc(2026, 9, 14))],
    );
    expect(result, isA<Success<NotificationPermission>>());
    expect(bridge.ownsDelivery(_completion('01')), isTrue);
    expect(bridge.ownsDelivery(_completion('02')), isFalse);

    // The next reconcile reports the cue acknowledged: it no longer owns it.
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      return <String, Object?>{
        'permission': 'granted',
        'delivered': <Object>[],
      };
    });
    await bridge.reconcile(
      operationId: _operation,
      intents: [_intent(suffix: '01', handled: true)],
    );
    expect(bridge.ownsDelivery(_completion('01')), isFalse);
    await bridge.dispose();
  });

  test('a failed sync never partially assumes ownership', () async {
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      return <String, Object?>{
        'permission': 'granted',
        'delivered': <Object>[_completion('01').value],
      };
    });
    final bridge = AndroidCompletionBridge(scheduler);
    await bridge.reconcile(operationId: _operation, intents: const []);
    expect(bridge.ownsDelivery(_completion('01')), isTrue);

    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      throw PlatformException(code: 'reconcile_failed');
    });
    final failed = await bridge.reconcile(
      operationId: _operation,
      intents: const [],
    );
    expect(failed, isA<Failure<NotificationPermission>>());
    expect(bridge.ownsDelivery(_completion('01')), isFalse);
    await bridge.dispose();
  });

  test('launch completions forward exactly one tap each', () async {
    var queued = <String?>['00000000-0000-0000-0003-0000000000aa', null];
    messenger.setMockMethodCallHandler(scheduler.channel, (_) async {
      if (queued.isEmpty) return null;
      return queued.removeAt(0);
    });
    final bridge = AndroidCompletionBridge(scheduler);
    final taps = <NotificationTap>[];
    final subscription = bridge.taps.listen(taps.add);
    await bridge.probeLaunchCompletion();
    await bridge.probeLaunchCompletion();
    await Future<void>.delayed(Duration.zero);
    expect(taps, hasLength(1));
    expect(
      taps.single.completionId.value,
      '00000000-0000-0000-0003-0000000000aa',
    );
    await subscription.cancel();
    await bridge.dispose();
  });

  test('permission and settings calls delegate unchanged', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(scheduler.channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'permission' => 'denied',
        'openSettings' => true,
        _ => null,
      };
    });
    final bridge = AndroidCompletionBridge(scheduler);
    expect(await bridge.permission(), NotificationPermission.denied);
    expect(
      await bridge.openSystemSettings(operationId: _operation),
      isA<Success<bool>>().having((r) => r.value, 'value', isTrue),
    );
    expect(calls, ['permission', 'openSettings']);
    await bridge.dispose();
  });
}
