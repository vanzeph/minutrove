import 'dart:math';

import '../../domain/domain.dart';

/// Read-only facts for presentation. Command validation still owns authority.
class ItemEditFacts {
  const ItemEditFacts({
    required this.hasHistory,
    required this.active,
    this.latestGoal,
  });
  final bool hasHistory;
  final bool active;
  final DailyGoalRevision? latestGoal;
}

typedef ReadItemEditFacts = Future<Result<ItemEditFacts>> Function(ItemId id);

/// Feature dependencies supplied by the composition root. No sample economics,
/// currency set, clock, or persistence implementation is selected by a form.
class ItemEditing {
  ItemEditing({
    required this.repository,
    required this.currencies,
    required this.readFacts,
    String Function()? newUuid,
  }) : newUuid = newUuid ?? randomUuid;
  final ItemRepository repository;
  final CurrencyMetadata currencies;
  final ReadItemEditFacts readFacts;
  final String Function() newUuid;
  OperationId operationId() => OperationId(newUuid());
}

String randomUuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String editingError(DomainError error) => switch (error) {
  InvalidInput(:final field, :final reason) => '$field: $reason.',
  NumericOverflow() => 'This value is too large. Enter a smaller amount.',
  UnsupportedDimensionalEdit() => 'History protects this item’s type, allowance dimensions and budget currency. Create another item to use different settings.',
  ActiveSessionConflict() => 'End this item’s active session before archiving.',
  StaleRevision() => 'This item or group changed elsewhere. Your draft is retained. Reload the latest version before saving.',
  NotFound() => 'The item or group is no longer available. Reload to continue.',
  StorageUnavailable() => 'Could not save to local storage. Your draft is retained. Retry when storage is available.',
  _ => 'The change could not be saved. Your draft is retained.',
};

String goalDate(DailyGoalRevision revision) {
  final date = revision.effectiveFrom;
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')} (${revision.zone.ianaName})';
}
