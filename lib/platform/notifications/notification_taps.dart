import '../../domain/domain.dart';

/// A notification tap carrying the identity the settled result is keyed by.
/// Routing opens Home with the committed result for this completion.
final class NotificationTap {
  const NotificationTap({required this.completionId});
  final CompletionId completionId;
}

/// Schedulers that can report whether the OS currently owns delivery of a
/// completion's deadline notification, and forward deduplicated taps. The
/// foreground fallback chime must not replay a delivery the OS already made.
abstract interface class CompletionDeliveryOwner {
  bool ownsDelivery(CompletionId completionId);
  Stream<NotificationTap> get taps;
}
