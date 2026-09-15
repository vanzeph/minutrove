import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/domain.dart';
import 'notification_taps.dart';

/// iOS adapter for the [NotificationScheduler] port. Talks to
/// `SessionNotifications.swift` over one method channel; every call is
/// sanitized so platform details never reach domain callers.
///
/// Permission answers map `provisional`/`ephemeral` authorization to
/// [NotificationPermission.granted] because those statuses still deliver
/// notifications; audible sound is decided by the OS sound setting, not here.
final class IosNotificationScheduler
    implements NotificationScheduler, CompletionDeliveryOwner {
  IosNotificationScheduler({
    this.channel = const MethodChannel(channelName),
    this.timeout = const Duration(seconds: 2),
  }) {
    channel.setMethodCallHandler(_handleNativeCall);
    // A cold-start tap can arrive before Dart registers this handler. Native
    // queued it; activation flushes that tap exactly once. Failures are
    // ignored: without a native side the queue is empty anyway.
    unawaited(
      channel
          .invokeMethod<void>('activateTapForwarding')
          .catchError((Object _) => null),
    );
  }

  static const channelName = 'io.github.vanzeph.minutrove/notifications';
  static const stablePrefix = 'minutrove.completion.';

  final MethodChannel channel;
  final Duration timeout;

  /// Completion IDs whose deadline notification the OS currently owns, from
  /// the last successful native sync. The foreground fallback chime must not
  /// replay a delivery the OS already made.
  final _osOwned = <CompletionId>{};

  /// Serializes native syncs so concurrent reconciles cannot interleave an
  /// add with a removal. Desired-state order defines the final OS state.
  Future<void> _syncTail = Future.value();

  final _permissionRequests = <OperationId, Future<NotificationPermission>>{};
  final _settingsRequests = <OperationId, Future<Result<bool>>>{};
  final _taps = StreamController<NotificationTap>.broadcast();
  final _tappedCompletionIds = <CompletionId>{};

  /// One routed event per completion, per process. A repeated tap on a stale
  /// delivered notification must not re-route Home.
  @override
  Stream<NotificationTap> get taps => _taps.stream;

  @override
  Future<NotificationPermission> permission() async {
    try {
      return _status(await _invoke<String>('permission'));
    } catch (_) {
      throw const StorageUnavailable(retryable: true);
    }
  }

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) => _permissionRequests.putIfAbsent(operationId, () async {
    try {
      final status = _status(
        await _invoke<String>('requestPermission', {
          'operationId': operationId.value,
        }),
      );
      _permissionRequests.remove(operationId);
      return status;
    } catch (_) {
      _permissionRequests.remove(operationId);
      throw const StorageUnavailable(retryable: true);
    }
  });

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) {
    // One serialized sync per call; the OS-side identifier replacement makes
    // the whole operation idempotent, and the operation ID remains available
    // as an idempotency key for callers that persist reconciliation results.
    final next = _syncTail.then((_) => _sync(operationId, intents));
    _syncTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Result<NotificationPermission>> _sync(
    OperationId operationId,
    List<NotificationIntent> intents,
  ) async {
    try {
      final permission = await this.permission();
      // Only an authorized app can expect delivery, so desired requests exist
      // solely for live deadlines under a grant. Denied or undetermined
      // states still cancel every stale identifier below.
      final desired = [
        for (final intent in intents)
          if (permission == NotificationPermission.granted &&
              intent.deadlineUtc != null)
            intent,
      ];
      final pending = (await _invoke<List<Object?>>('syncRequests', {
        'operationId': operationId.value,
        'desired': [
          for (final intent in desired)
            {
              'completionId': intent.completionId.value,
              'deadlineMilliseconds':
                  intent.deadlineUtc!.millisecondsSinceEpoch,
            },
        ],
      }))?.cast<String>();
      final owned = <CompletionId>{
        for (final identifier in pending ?? const <String>[])
          if (identifier.startsWith(stablePrefix) &&
              identifier.length > stablePrefix.length)
            CompletionId(identifier.substring(stablePrefix.length)),
      };
      _osOwned
        ..clear()
        ..addAll(owned);
      return Success(permission);
    } catch (_) {
      // The OS state is unknown, never partially assumed: drop ownership so a
      // later foreground completion can fall back to the immediate chime.
      _osOwned.clear();
      return const Failure(StorageUnavailable(retryable: true));
    }
  }

  @override
  Future<Result<bool>> openSystemSettings({required OperationId operationId}) =>
      _settingsRequests.putIfAbsent(operationId, () async {
        try {
          await _invoke<void>('openSettings', {
            'operationId': operationId.value,
          });
          _settingsRequests.remove(operationId);
          return const Success<bool>(true);
        } catch (_) {
          _settingsRequests.remove(operationId);
          return const Failure(StorageUnavailable(retryable: true));
        }
      });

  @override
  bool ownsDelivery(CompletionId completionId) =>
      _osOwned.contains(completionId);

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onNotificationTap':
        final id = (call.arguments as Map<Object?, Object?>)['completionId'];
        if (id is String && _tappedCompletionIds.add(CompletionId(id))) {
          _taps.add(NotificationTap(completionId: CompletionId(id)));
        }
        return null;
      default:
        throw PlatformException(code: 'unknown_notification_call');
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) =>
      channel.invokeMethod<T>(method, arguments).timeout(timeout);

  static NotificationPermission _status(String? value) => switch (value) {
    'granted' || 'provisional' || 'ephemeral' => NotificationPermission.granted,
    'denied' => NotificationPermission.denied,
    'restricted' => NotificationPermission.restricted,
    'notDetermined' => NotificationPermission.notDetermined,
    _ => throw const FormatException('Invalid permission status'),
  };
}
