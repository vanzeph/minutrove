import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/notifications/ios_notification_scheduler.dart';
import 'package:minutrove/platform/notifications/notification_taps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(IosNotificationScheduler.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  NotificationIntent intent({
    String id = '11111111-1111-4111-8111-111111111111',
    DateTime? deadline,
    bool handled = false,
  }) => NotificationIntent(
    sessionId: SessionId(id),
    sessionRevision: Revision(1),
    completionId: CompletionId(id),
    deadlineUtc: deadline,
    completionChimeHandled: handled,
  );

  test('permission maps every native status without leaking details', () async {
    for (final entry in {
      'granted': NotificationPermission.granted,
      'provisional': NotificationPermission.granted,
      'ephemeral': NotificationPermission.granted,
      'denied': NotificationPermission.denied,
      'restricted': NotificationPermission.restricted,
      'notDetermined': NotificationPermission.notDetermined,
    }.entries) {
      messenger.setMockMethodCallHandler(channel, (_) async => entry.key);
      expect(
        await IosNotificationScheduler().permission(),
        entry.value,
        reason: entry.key,
      );
    }
    for (final bad in [null, 'unknown', 3]) {
      messenger.setMockMethodCallHandler(channel, (_) async => bad);
      await expectLater(
        IosNotificationScheduler().permission(),
        throwsA(
          isA<StorageUnavailable>().having(
            (e) => e.retryable,
            'retryable',
            true,
          ),
        ),
        reason: '$bad',
      );
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'private-details'),
    );
    await expectLater(
      IosNotificationScheduler().permission(),
      throwsA(isA<StorageUnavailable>()),
    );
  });

  test('contextual permission request asks once per operation', () async {
    final calls = <MethodCall>[];
    String? answer;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'permission' ? answer : answer ?? 'notDetermined';
    });
    final scheduler = IosNotificationScheduler();
    final operation = OperationId('00000000-0000-4000-8000-0000000000a1');
    final first = scheduler.requestPermission(operationId: operation);
    final concurrent = scheduler.requestPermission(operationId: operation);
    expect(await first, NotificationPermission.notDetermined);
    expect(await concurrent, NotificationPermission.notDetermined);
    final requests = calls.where((call) => call.method == 'requestPermission');
    expect(
      requests,
      hasLength(1),
      reason: 'concurrent duplicates share one prompt',
    );
    expect(
      (requests.single.arguments as Map<Object?, Object?>)['operationId'],
      operation.value,
    );
    answer = 'granted';
    expect(
      await scheduler.requestPermission(operationId: operation),
      NotificationPermission.granted,
      reason: 'a settled decision answers without prompting again',
    );
    expect(
      calls.where((call) => call.method == 'requestPermission'),
      hasLength(2),
    );
  });

  test(
    'reconcile schedules granted deadlines with stable request ids',
    () async {
      final calls = <MethodCall>[];
      final deadline = DateTime.utc(2026, 9, 14, 12);
      final granted = intent(deadline: deadline);
      final terminal = intent(
        id: '22222222-2222-4222-8222-222222222222',
        deadline: null,
        handled: false,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'permission' => 'granted',
          'syncRequests' => const [
            'minutrove.completion.11111111-1111-4111-8111-111111111111',
          ],
          _ => null,
        };
      });
      final scheduler = IosNotificationScheduler();
      final result = await scheduler.reconcile(
        operationId: OperationId('00000000-0000-4000-8000-0000000000b2'),
        intents: [granted, terminal],
      );
      expect(result, isA<Success<NotificationPermission>>());
      expect(
        (result as Success<NotificationPermission>).value,
        NotificationPermission.granted,
      );
      final sync =
          calls.where((call) => call.method == 'syncRequests').single.arguments
              as Map<Object?, Object?>;
      final desired = sync['desired'] as List<Object?>;
      expect(desired, hasLength(1));
      expect(
        (desired.single as Map<Object?, Object?>)['completionId'],
        granted.completionId.value,
      );
      expect(
        (desired.single as Map<Object?, Object?>)['deadlineMilliseconds'],
        deadline.millisecondsSinceEpoch,
      );
      expect(
        scheduler.ownsDelivery(granted.completionId),
        isTrue,
        reason: 'the OS owns the only scheduled deadline sound',
      );
      expect(scheduler.ownsDelivery(terminal.completionId), isFalse);
    },
  );

  test(
    'denied permission cancels desired requests but stays correct',
    () async {
      final desiredStates = <List<Object?>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'permission':
            return 'denied';
          case 'syncRequests':
            desiredStates.add(
              (call.arguments as Map<Object?, Object?>)['desired']
                  as List<Object?>,
            );
            return const <String>[];
        }
        return null;
      });
      final scheduler = IosNotificationScheduler();
      final result = await scheduler.reconcile(
        operationId: OperationId('00000000-0000-4000-8000-0000000000c3'),
        intents: [intent(deadline: DateTime.utc(2026, 9, 14, 12))],
      );
      expect(result, isA<Success<NotificationPermission>>());
      expect(
        (result as Success<NotificationPermission>).value,
        NotificationPermission.denied,
      );
      expect(
        desiredStates.single,
        isEmpty,
        reason: 'no delivery is expected while denied',
      );
      expect(scheduler.ownsDelivery(intent().completionId), isFalse);
    },
  );

  test(
    'pause, resume and end reconcile through one desired-state sync',
    () async {
      final desiredStates = <List<Object?>>[];
      final pending = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'permission':
            return 'granted';
          case 'syncRequests':
            desiredStates.add(
              (call.arguments as Map<Object?, Object?>)['desired']
                  as List<Object?>,
            );
            return List<String>.of(pending);
        }
        return null;
      });
      final scheduler = IosNotificationScheduler();
      final operation = OperationId('00000000-0000-4000-8000-0000000000d4');
      final running = intent(deadline: DateTime.utc(2026, 9, 14, 12));
      // start: schedule the run deadline
      pending.add('minutrove.completion.${running.completionId.value}');
      await scheduler.reconcile(operationId: operation, intents: [running]);
      expect(scheduler.ownsDelivery(running.completionId), isTrue);
      // pause: a null deadline explicitly cancels the request
      pending.clear();
      await scheduler.reconcile(operationId: operation, intents: [intent()]);
      expect(scheduler.ownsDelivery(running.completionId), isFalse);
      // resume: a new deadline replaces the same stable identifier
      pending.add('minutrove.completion.${running.completionId.value}');
      await scheduler.reconcile(
        operationId: operation,
        intents: [intent(deadline: DateTime.utc(2026, 9, 14, 13))],
      );
      // end: nothing remains pending
      pending.clear();
      await scheduler.reconcile(operationId: operation, intents: [intent()]);

      expect(desiredStates.map((list) => list.length), [1, 0, 1, 0]);
      final identifiers = desiredStates
          .where((list) => list.isNotEmpty)
          .map((list) => (list.single as Map<Object?, Object?>)['completionId'])
          .toSet();
      expect(identifiers, {
        running.completionId.value,
      }, reason: 'rescheduling keeps one stable identifier per session');
    },
  );

  test('native sync failure fails closed and drops OS ownership', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'permission' => 'granted',
        'syncRequests' => throw PlatformException(code: 'sync_failed'),
        _ => null,
      };
    });
    final scheduler = IosNotificationScheduler();
    final result = await scheduler.reconcile(
      operationId: OperationId('00000000-0000-4000-8000-0000000000e5'),
      intents: [intent(deadline: DateTime.utc(2026, 9, 14, 12))],
    );
    expect(result, isA<Failure<NotificationPermission>>());
    expect(
      (result as Failure<NotificationPermission>).error,
      isA<StorageUnavailable>().having((e) => e.retryable, 'retryable', true),
    );
    expect(scheduler.ownsDelivery(intent().completionId), isFalse);
  });

  test('concurrent reconciles serialize instead of interleaving', () async {
    final order = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permission':
          return 'granted';
        case 'syncRequests':
          if (order.isNotEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          order.add('sync');
          return const <String>[];
      }
      return null;
    });
    final scheduler = IosNotificationScheduler();
    final results = await Future.wait([
      scheduler.reconcile(
        operationId: OperationId('00000000-0000-4000-8000-0000000000f6'),
        intents: const [],
      ),
      scheduler.reconcile(
        operationId: OperationId('00000000-0000-4000-8000-0000000000f7'),
        intents: const [],
      ),
    ]);
    expect(order, ['sync', 'sync']);
    expect(results, everyElement(isA<Success<NotificationPermission>>()));
  });

  test('openSystemSettings reports typed failures only', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final scheduler = IosNotificationScheduler();
    final operation = OperationId('00000000-0000-4000-8000-0000000000a7');
    expect(
      await scheduler.openSystemSettings(operationId: operation),
      isA<Success<bool>>(),
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'settings_failed'),
    );
    expect(
      await scheduler.openSystemSettings(operationId: operation),
      isA<Failure<bool>>(),
    );
  });

  test('taps route once per completion and survive cold-start queueing', () async {
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    final scheduler = IosNotificationScheduler();
    // The constructor activates forwarding so a queued cold-start tap flushes.
    await Future<void>.delayed(Duration.zero);
    expect(
      nativeCalls.where((call) => call.method == 'activateTapForwarding'),
      isNotEmpty,
    );
    final taps = <NotificationTap>[];
    scheduler.taps.listen(taps.add);
    Future<void> deliver(String id) => messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onNotificationTap', {'completionId': id}),
      ),
      (_) {},
    );
    await deliver('99999999-9999-4999-8999-999999999999');
    await deliver('99999999-9999-4999-8999-999999999999');
    await deliver('88888888-8888-4888-8888-888888888888');
    await Future<void>.delayed(Duration.zero);
    expect(taps.map((tap) => tap.completionId.value), const [
      '99999999-9999-4999-8999-999999999999',
      '88888888-8888-4888-8888-888888888888',
    ], reason: 'a repeated tap on the same completion never re-routes Home');
  });
}
