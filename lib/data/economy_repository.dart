import '../domain/domain.dart';
import 'award_redemption_repository.dart';
import 'command_coordinator.dart';
import 'session_repository.dart';
import 'sqlite_store.dart';

/// Purchases and consumption share the session/item command transaction queue.
final class SqliteEconomyRepository implements EconomyRepository {
  SqliteEconomyRepository({
    required this.store,
    required this.clock,
    required this.calendar,
  }) : _purchases = SqliteAwardRedemptionRepository(
         store: store,
         clock: clock,
         calendar: calendar,
       );

  final SqliteStore store;
  final Clock clock;
  final ReportingCalendar calendar;
  final SqliteAwardRedemptionRepository _purchases;

  @override
  Stream<WalletProjection> watchWallet() => _purchases.watchWallet();

  @override
  Stream<List<AwardBalance>> watchAwards() => _purchases.watchAwards();

  @override
  Future<Result<RedemptionPreview>> previewAward({
    required ItemId awardId,
    required PurchaseQuantity quantity,
  }) => _purchases.previewAward(awardId: awardId, quantity: quantity);

  @override
  Future<Result<EconomicState>> redeemAward({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedRevision,
    required PurchaseQuantity quantity,
  }) => _purchases.redeemAward(
    operationId: operationId,
    awardId: awardId,
    expectedRevision: expectedRevision,
    quantity: quantity,
  );

  @override
  Future<Result<EconomicState>> recordExpense({
    required OperationId operationId,
    required ItemId awardId,
    required Revision expectedBalanceRevision,
    required BudgetAmount expense,
    required SessionConflictChoice conflictChoice,
  }) {
    late ClockReading reading;
    late EventTime timestamp;
    return CommandCoordinator(store).execute(
      operationId: operationId,
      request: CommandRequest(
        kind: OperationKind.recordExpense,
        arguments: {
          'awardId': awardId.value,
          'expectedBalanceRevision': expectedBalanceRevision.value,
          'expenseCurrency': expense.currency.code,
          'expenseMinorDigits': expense.currency.minorDigits,
          'expenseMinorUnits': expense.minorUnits,
          'conflictChoice': conflictChoice.name,
        },
      ),
      committedAt: (records) async {
        reading = clock.now();
        final zone = (await records.settings()).reportingZone;
        if (!calendar.supports(zone)) {
          throw const InvalidInput(
            'reportingZone',
            'Unsupported reporting zone',
          );
        }
        return timestamp = calendar.assign(reading.utc, zone);
      },
      action: (command) async {
        final item = await command.records.item(awardId);
        if (item == null) throw const NotFound();
        if (item.configuration is! AwardConfiguration) {
          throw const InvalidInput('award', 'Expected an owned budget Award');
        }
        final balance = await command.requireAward(
          awardId,
          expectedBalanceRevision,
        );
        final budget = balance?.budget;
        if (budget == null) {
          throw const InvalidInput('award', 'No owned budget allowance');
        }
        // Validate the caller's revision before settlement can advance it when
        // the active session belongs to this same combined Award.
        budget.spend(expense);
        final active = await command.records.activeSession();
        if (active != null) {
          if (conflictChoice == SessionConflictChoice.cancel) {
            throw const ActiveSessionConflict();
          }
          await SessionSettlement(calendar).apply(
            command: command,
            session: active,
            reading: reading,
            action: SessionAction.end,
          );
        }
        // Session settlement only consumes time/earns currencies. Post the
        // expense against the resulting projection in this same transaction.
        await command.postLedger([
          LedgerEntry(
            id: LedgerId(operationId.value),
            operationId: operationId,
            itemId: item.id,
            itemRevision: item.revision,
            sessionId: null,
            timestamp: timestamp,
            dimension: BudgetDimension(budget.currency),
            delta: -expense.minorUnits,
          ),
        ]);
        return command.economicState();
      },
    );
  }
}
