import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/domain.dart';

/// One completion cue outcome: the OS permission state plus the completions
/// whose scheduled notification was already delivered and remains
/// unacknowledged. The composition layer uses [delivered] to suppress a
/// duplicate foreground chime after OS delivery, then reports
/// `completionChimeHandled` through a later reconcile to clear the cue.
final class NotificationReconciliation {
  const NotificationReconciliation({
    required this.permission,
    required this.delivered,
  });
  final NotificationPermission permission;
  final Set<CompletionId> delivered;
}

/// Android adapter for the [NotificationScheduler] port over the
/// `io.github.vanzeph.minutrove/notifications` method channel.
///
/// Reconcile is the only mutating entry point: it replaces native alarm and
/// notification state to match the persisted intents, so pause, resume, end,
/// restore and crash recovery converge through one idempotent call. Native
/// failures surface as retryable [StorageUnavailable] without guessing state.
/// The native side owns exact-vs-inexact scheduling policy; delivery timing is
/// best effort and settlement never depends on it.
final class AndroidNotificationScheduler implements NotificationScheduler {
  const AndroidNotificationScheduler({
    this.channel = const MethodChannel(channelName),
    this.timeout = const Duration(seconds: 2),
  });

  static const channelName = 'io.github.vanzeph.minutrove/notifications';

  final MethodChannel channel;
  final Duration timeout;

  @override
  Future<NotificationPermission> permission() async =>
      _permission(await _invoke('permission'));

  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) async {
    // No timeout: the native call may wait on the system permission dialog.
    try {
      final value = await channel.invokeMethod<String>('requestPermission', {
        'operationId': operationId.value,
      });
      return _permission(value);
    } catch (_) {
      // Do not fabricate a permission state from a failed native call.
      throw const StorageUnavailable(retryable: true);
    }
  }

  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    final detailed = await reconcileDetailed(
      operationId: operationId,
      intents: intents,
    );
    return switch (detailed) {
      Success<NotificationReconciliation>(:final value) => Success(
        value.permission,
      ),
      Failure<NotificationReconciliation>(:final error) => Failure(error),
    };
  }

  Future<Result<NotificationReconciliation>> reconcileDetailed({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    try {
      final value = await channel
          .invokeMapMethod<String, Object?>('reconcile', {
            'operationId': operationId.value,
            'intents': [
              for (final intent in intents)
                {
                  'sessionId': intent.sessionId.value,
                  'sessionRevision': intent.sessionRevision.value,
                  'completionId': intent.completionId.value,
                  'deadlineUtcMilliseconds':
                      intent.deadlineUtc?.millisecondsSinceEpoch,
                  'handled': intent.completionChimeHandled,
                },
            ],
          })
          .timeout(timeout);
      final permission = _permission(value?['permission']);
      final deliveredRaw = value?['delivered'];
      if (value == null || !value.containsKey('delivered')) {
        throw const FormatException('Missing delivered completions');
      }
      if (deliveredRaw != null && deliveredRaw is! List) {
        throw const FormatException('Invalid delivered completions');
      }
      final deliveredList = deliveredRaw as List?;
      final delivered = <CompletionId>{
        for (final item in deliveredList ?? const [])
          if (item is String && _isUuid(item)) CompletionId(item),
      };
      if (delivered.length != (deliveredList ?? const []).length) {
        throw const FormatException('Invalid delivered completion identity');
      }
      return Success(
        NotificationReconciliation(
          permission: permission,
          delivered: delivered,
        ),
      );
    } catch (_) {
      // Alarm and notification state remain whatever the last successful
      // reconcile left; the next reconcile converges again.
      return const Failure(StorageUnavailable(retryable: true));
    }
  }

  @override
  Future<Result<bool>> openSystemSettings({
    required OperationId operationId,
  }) async {
    try {
      final value = await channel
          .invokeMethod<bool>('openSettings')
          .timeout(timeout);
      if (value == null) throw const FormatException('Invalid settings result');
      return Success(value);
    } catch (_) {
      return const Failure(StorageUnavailable(retryable: true));
    }
  }

  /// Consumes the completion ID from a notification tap that launched or
  /// re-entered the app, for routing Home with the settled result. Each tap is
  /// reported exactly once; null means the launch was not a completion cue.
  Future<CompletionId?> consumeLaunchCompletion() async {
    try {
      final value = await channel
          .invokeMethod<String?>('consumeLaunchCompletion')
          .timeout(timeout);
      if (value == null) return null;
      if (value.isEmpty || !_isUuid(value)) {
        throw const FormatException('Invalid launch completion');
      }
      return CompletionId(value);
    } catch (_) {
      return null;
      // Tap routing is best effort; losing one cue to a channel failure must
      // not surface a storage error to the user.
    }
  }

  Future<Object?> _invoke(String method) async {
    try {
      return await channel.invokeMethod<Object?>(method).timeout(timeout);
    } catch (_) {
      // Never substitute a guessed permission state for a failed sample.
      throw const StorageUnavailable(retryable: true);
    }
  }

  NotificationPermission _permission(Object? value) {
    if (value is! String) {
      throw const StorageUnavailable(retryable: true);
    }
    return switch (value) {
      'granted' => NotificationPermission.granted,
      'denied' => NotificationPermission.denied,
      'notDetermined' => NotificationPermission.notDetermined,
      'restricted' => NotificationPermission.restricted,
      _ => throw const StorageUnavailable(retryable: true),
    };
  }
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value);
