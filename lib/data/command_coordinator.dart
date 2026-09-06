import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/domain.dart';
import 'sqlite_store.dart';
import 'store_records.dart';

/// Freeze every caller-controlled argument, including expected revisions and
/// conflict choices. Omit generated IDs, current time and derived state. Maps
/// are key-sorted recursively; list order and explicit nulls are significant.
final class CommandRequest {
  CommandRequest({required this.kind, required Map<String, Object?> arguments})
    : fingerprint = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'version': 1,
                'kind': kind.name,
                'arguments': _canonical(arguments),
              }),
            ),
          )
          .toString();

  final OperationKind kind;
  final String fingerprint;
}

Object? _canonical(Object? value) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is List) return value.map(_canonical).toList();
  if (value is Map<String, Object?>) {
    return {
      for (final key in value.keys.toList()..sort())
        key: _canonical(value[key]),
    };
  }
  throw const InvalidInput('request', 'Use exact integer JSON arguments');
}

/// Shares SqliteStore's single queue with every other repository mutation.
/// Replay precedes current revision checks and clock reads. The original result,
/// ledger, projections and related records become visible at one SQLite COMMIT.
final class CommandCoordinator {
  const CommandCoordinator(this.store);
  final SqliteStore store;

  Future<Result<T>> execute<T extends Object>({
    required OperationId operationId,
    required CommandRequest request,
    required FutureOr<EventTime> Function(StoreReader records) committedAt,
    required Future<T> Function(CommandTransaction command) action,
  }) => store.write((records) async {
    // Decode as Object first: an ID reused by another command/result type is
    // conflicting input, not a storage failure caused by a premature cast.
    final prior = await records.operation<Object>(operationId);
    if (prior != null) {
      if (prior.kind != request.kind ||
          prior.requestFingerprint != request.fingerprint ||
          prior.committedResult is! T) {
        throw const InvalidInput('operationId', 'Conflicting operation reuse');
      }
      return prior.committedResult as T;
    }
    final timestamp = await committedAt(records);
    final command = CommandTransaction._(records, operationId);
    final value = await action(command);
    await command._validateResult(value);
    // Detach mutable results (e.g. item lists) before saving or acknowledging.
    final frozen = records.codec.decode<T>(records.codec.encode(value));
    await records.insertOperation(
      Operation(
        id: operationId,
        kind: request.kind,
        committedAt: timestamp,
        requestFingerprint: request.fingerprint,
        committedResult: frozen,
      ),
    );
    return frozen;
  });
}

/// Only valid inside execute's callback. Await all operations. Related session,
/// remainder, achievement and notification writes use these same [records].
/// Throw DomainError on rejection; never catch a failed write and keep going.
final class CommandTransaction {
  CommandTransaction._(this.records, this.operationId);
  final StoreTransaction records;
  final OperationId operationId;

  Future<Item> requireItem(ItemId id, Revision expectedRevision) async {
    final item = await records.item(id);
    if (item == null) throw const NotFound();
    _checkRevision(item.revision, expectedRevision);
    return item;
  }

  Future<Session> requireSession(
    SessionId id,
    Revision expectedRevision,
  ) async {
    final session = await records.session(id);
    if (session == null) throw const NotFound();
    _checkRevision(session.revision, expectedRevision);
    return session;
  }

  /// Null expects an absent pooled balance, as on its first purchase.
  Future<AwardBalance?> requireAward(
    ItemId id,
    Revision? expectedRevision,
  ) async {
    final award = await records.award(id);
    _checkRevision(award?.revision, expectedRevision);
    return award;
  }

  Future<WalletProjection> requireWallet(Revision expectedRevision) async {
    final wallet = await records.wallet();
    _checkRevision(wallet.revision, expectedRevision);
    return wallet;
  }

  /// Append one batch and derive the corresponding projections. Historical
  /// item revisions are valid for session settlement; commands requiring the
  /// current quote must call requireItem first. Deltas retain their own units.
  Future<void> postLedger(Iterable<LedgerEntry> input) async {
    final entries = List<LedgerEntry>.of(input);
    if (entries.isEmpty) return;
    var coins = BigInt.zero;
    var gems = BigInt.zero;
    var walletChanged = false;
    final awards = <ItemId, _AwardDelta>{};
    final ids = <LedgerId>{};
    for (final entry in entries) {
      if (entry.operationId != operationId || !ids.add(entry.id)) {
        throw const InvalidInput(
          'ledger',
          'Wrong operation or duplicate entry',
        );
      }
      final revision = await records.itemRevision(
        entry.itemId,
        entry.itemRevision,
      );
      if (revision == null) throw const NotFound();
      final item = revision.snapshot;
      if (entry.sessionId != null) {
        final session = await records.session(entry.sessionId!);
        if (session == null ||
            session.itemSnapshot.id != item.id ||
            session.itemSnapshot.revision != item.revision) {
          throw const InvalidInput('ledger', 'Session snapshot differs');
        }
      }
      final delta = BigInt.from(entry.delta);
      switch (entry.dimension) {
        case VirtualCurrencyDimension(:final currency):
          walletChanged = true;
          if (currency == VirtualCurrency.coins) {
            coins += delta;
          } else {
            gems += delta;
          }
        case TimeDimension() when item.type == ItemType.quest:
          if (delta.isNegative) {
            throw const InvalidInput(
              'ledger',
              'Quest active time is nonnegative',
            );
          }
        case TimeDimension() || BudgetDimension():
          final config = item.configuration;
          if (config is! AwardConfiguration) {
            throw const InvalidInput('ledger', 'Allowance requires an Award');
          }
          final change = awards.putIfAbsent(item.id, () => _AwardDelta(config));
          if ((change.config.timeGrant == null) != (config.timeGrant == null) ||
              change.config.budgetGrant?.currency !=
                  config.budgetGrant?.currency) {
            throw const InvalidInput('ledger', 'Incompatible Award dimensions');
          }
          switch (entry.dimension) {
            case TimeDimension():
              if (config.timeGrant == null) {
                throw const InvalidInput('ledger', 'Award has no time');
              }
              change.time += delta;
            case BudgetDimension(:final currency):
              if (config.budgetGrant?.currency != currency) {
                throw const InvalidInput('ledger', 'Unlike budget currencies');
              }
              change.budget += delta;
            case VirtualCurrencyDimension():
              throw StateError('Unreachable dimension');
          }
      }
    }

    // Validate every resulting amount and revision before the first ledger write.
    WalletProjection? wallet;
    if (walletChanged) {
      final old = await records.wallet();
      coins += BigInt.from(old.balances.coins.units);
      gems += BigInt.from(old.balances.gems.units);
      if (coins.isNegative || gems.isNegative) {
        throw InsufficientFunds(coins: coins.isNegative, gems: gems.isNegative);
      }
      wallet = WalletProjection(
        revision: old.revision.next(),
        balances: CurrencyAmounts(
          coins: MicroAmount(checkedInteger(coins)),
          gems: MicroAmount(checkedInteger(gems)),
        ),
      );
    }
    final balances = <AwardBalance>[];
    for (final MapEntry(key: id, value: change) in awards.entries) {
      final old = await records.award(id);
      final config = change.config;
      if (old != null &&
          ((old.time == null) != (config.timeGrant == null) ||
              old.budget?.currency != config.budgetGrant?.currency)) {
        throw const InvalidInput(
          'ledger',
          'Stored allowance dimensions differ',
        );
      }
      final time = BigInt.from(old?.time?.value ?? 0) + change.time;
      final budget = BigInt.from(old?.budget?.minorUnits ?? 0) + change.budget;
      if (time.isNegative || budget.isNegative) throw const AllowanceExceeded();
      balances.add(
        AwardBalance(
          awardId: id,
          revision: old?.revision.next() ?? Revision(1),
          time: config.timeGrant == null
              ? null
              : Milliseconds(checkedInteger(time)),
          budget: config.budgetGrant == null
              ? null
              : BudgetAmount(
                  config.budgetGrant!.currency,
                  checkedInteger(budget),
                ),
        ),
      );
    }
    for (final entry in entries) {
      await records.insertLedger(entry);
    }
    if (wallet != null) await records.putWallet(wallet);
    for (final balance in balances) {
      await records.putAward(balance);
    }
  }

  /// Call after all mutations; includes this operation's ledger/achievements
  /// and the full committed wallet, pooled allowances and active session.
  Future<EconomicState> economicState() async => EconomicState(
    operationId: operationId,
    wallet: await records.wallet(),
    awards: await records.awards(),
    activeSession: await records.activeSession(),
    entries: await records.ledger(operationId: operationId),
    achievements: (await records.achievements())
        .where((value) => value.operationId == operationId)
        .toList(),
  );

  Future<void> _validateResult(Object value) async {
    final economy = switch (value) {
      EconomicState v => v,
      SessionMutation v => v.economy,
      _ => null,
    };
    if (economy != null &&
        records.codec.encode(economy) !=
            records.codec.encode(await economicState())) {
      throw const InvalidInput('result', 'Return the final economic state');
    }
    if (value is SessionMutation) {
      final session = await records.session(value.session.id);
      final intents = await records.notificationIntents();
      if (session == null ||
          records.codec.encode(session) !=
              records.codec.encode(value.session) ||
          !intents.any(
            (intent) =>
                records.codec.encode(intent) ==
                records.codec.encode(value.notificationIntent),
          ) ||
          value.notificationIntent.sessionId != session.id ||
          value.notificationIntent.sessionRevision != session.revision ||
          value.notificationIntent.completionId != session.completionId ||
          value.notificationIntent.deadlineUtc != session.deadlineUtc) {
        throw const InvalidInput(
          'result',
          'Return the saved session and intent',
        );
      }
    }
  }
}

void _checkRevision(Revision? current, Revision? expected) {
  if (current != expected) throw const StaleRevision();
}

final class _AwardDelta {
  _AwardDelta(this.config);
  final AwardConfiguration config;
  BigInt time = BigInt.zero;
  BigInt budget = BigInt.zero;
}
