import 'dart:math';

import '../domain/domain.dart';
import 'command_coordinator.dart';
import 'sqlite_store.dart';
import 'store_records.dart';

/// Purchase/read portion of EconomyRepository. The economy adapter delegates
/// these methods here and supplies expense/session settlement separately.
final class SqliteAwardRedemptionRepository {
  SqliteAwardRedemptionRepository({
    required this.store,
    required this.clock,
    required this.calendar,
    LedgerId Function()? newLedgerId,
  }) : _commands = CommandCoordinator(store),
       _newLedgerId = newLedgerId ?? _randomLedgerId;

  final SqliteStore store;
  final Clock clock;
  final ReportingCalendar calendar;
  final CommandCoordinator _commands;
  final LedgerId Function() _newLedgerId;

  Stream<WalletProjection> watchWallet() => store.watch((r) => r.wallet());

  /// Retains exhausted and archived balances; the Home view filters isExhausted.
  Stream<List<AwardBalance>> watchAwards() => store.watch((r) => r.awards());

  Future<Result<RedemptionPreview>> previewAward({
    required ItemId awardId,
    required PurchaseQuantity quantity,
  }) async {
    final result = await store.read<Result<RedemptionPreview>>((records) async {
      final item = await records.item(awardId);
      if (item == null) return const Failure(NotFound());
      return _preview(records, item, quantity);
    });
    // Keep business rejections distinct from malformed-storage read failures.
    return switch (result) {
      Success<Result<RedemptionPreview>>(:final value) => value,
      Failure<Result<RedemptionPreview>>(:final error) => Failure(error),
    };
  }

  Future<Result<EconomicState>> redeemAward({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedRevision,
    required PurchaseQuantity quantity,
  }) {
    late EventTime timestamp;
    return _commands.execute(
      operationId: operationId,
      request: CommandRequest(
        kind: OperationKind.redeemAward,
        arguments: {
          'awardId': awardId.value,
          'expectedRevision': expectedRevision.value,
          'quantity': quantity.value,
        },
      ),
      committedAt: (records) async {
        final zone = (await records.settings()).reportingZone;
        if (!calendar.supports(zone)) {
          throw const InvalidInput(
            'reportingZone',
            'Unsupported reporting zone',
          );
        }
        return timestamp = calendar.assign(clock.now().utc, zone);
      },
      action: (command) async {
        final item = await command.requireItem(awardId, expectedRevision);
        final preview = switch (await _preview(
          command.records,
          item,
          quantity,
        )) {
          Success<RedemptionPreview>(:final value) => value,
          Failure<RedemptionPreview>(:final error) => throw error,
        };
        final entries = <LedgerEntry>[];
        void add(LedgerDimension dimension, int delta) {
          if (delta == 0) return;
          entries.add(
            LedgerEntry(
              id: _newLedgerId(),
              operationId: operationId,
              itemId: item.id,
              itemRevision: item.revision,
              sessionId: null,
              timestamp: timestamp,
              dimension: dimension,
              delta: delta,
            ),
          );
        }

        add(
          const VirtualCurrencyDimension(VirtualCurrency.coins),
          -preview.totalPrice.coins.units,
        );
        add(
          const VirtualCurrencyDimension(VirtualCurrency.gems),
          -preview.totalPrice.gems.units,
        );
        if (preview.timeGrant case final time?) {
          add(const TimeDimension(), time.value);
        }
        if (preview.budgetGrant case final budget?) {
          add(BudgetDimension(budget.currency), budget.minorUnits);
        }
        await command.postLedger(entries);
        return command.economicState();
      },
    );
  }
}

Future<Result<RedemptionPreview>> _preview(
  StoreReader records,
  Item item,
  PurchaseQuantity quantity,
) async {
  final result = previewRedemption(
    award: item,
    quantity: quantity,
    wallet: (await records.wallet()).balances,
  );
  if (result is Failure<RedemptionPreview>) return result;
  final preview = (result as Success<RedemptionPreview>).value;
  // A valid per-purchase grant can still overflow an existing pooled allowance.
  // Check during preview too, so confirmation never knowingly offers that grant.
  final owned = await records.award(item.id);
  try {
    if (preview.timeGrant case final time?) {
      checkedInteger(
        BigInt.from(owned?.time?.value ?? 0) + BigInt.from(time.value),
      );
    }
    if (preview.budgetGrant case final budget?) {
      checkedInteger(
        BigInt.from(owned?.budget?.minorUnits ?? 0) +
            BigInt.from(budget.minorUnits),
      );
    }
  } on DomainError catch (error) {
    return Failure(error);
  }
  return Success(preview);
}

LedgerId _randomLedgerId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return LedgerId(
    '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
    '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}',
  );
}
