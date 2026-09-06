import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/domain.dart';
import '../home/home_data.dart';
import '../items/item_editing.dart';

/// A display quote from one committed snapshot. Transactional redemption repeats
/// validation, including the item revision and both pooled allowance dimensions.
class PurchaseSummary {
  PurchaseSummary(HomeData data, Item item, this.quantity) {
    final config = item.configuration as AwardConfiguration;
    final wallet = data.wallet.balances;
    maximumAffordable = wallet.maximumAffordableQuantity(config.price);
    maximumPurchasable = maximumAffordable;
    final owned = data.awards[item.id];
    void limit(int? grant, int balance) {
      if (grant != null) {
        maximumPurchasable = math.min(
          maximumPurchasable,
          (maxStoredInteger - balance) ~/ grant,
        );
      }
    }

    limit(config.timeGrant?.value, owned?.time?.value ?? 0);
    limit(config.budgetGrant?.minorUnits, owned?.budget?.minorUnits ?? 0);
    try {
      total = config.price.times(quantity);
      time = config.timeGrant?.times(quantity);
      budget = config.budgetGrant?.times(quantity);
      if (time != null) {
        pooledTime = Milliseconds(
          checkedInteger(
            BigInt.from(owned?.time?.value ?? 0) + BigInt.from(time!.value),
          ),
        );
      }
      if (budget != null) {
        pooledBudget = BudgetAmount(
          budget!.currency,
          checkedInteger(
            BigInt.from(owned?.budget?.minorUnits ?? 0) +
                BigInt.from(budget!.minorUnits),
          ),
        );
      }
      missingCoins = math.max(0, total!.coins.units - wallet.coins.units);
      missingGems = math.max(0, total!.gems.units - wallet.gems.units);
      if (missingCoins == 0 && missingGems == 0) after = wallet - total!;
    } on NumericOverflow {
      overflow = true;
    }
  }

  final int quantity;
  late final int maximumAffordable;
  late int maximumPurchasable;
  CurrencyAmounts? total;
  CurrencyAmounts? after;
  Milliseconds? time;
  Milliseconds? pooledTime;
  BudgetAmount? budget;
  BudgetAmount? pooledBudget;
  int missingCoins = 0;
  int missingGems = 0;
  bool overflow = false;
  bool get canPurchase => !overflow && after != null;
}

class _PurchaseRequest {
  const _PurchaseRequest(this.operationId, this.revision, this.quantity);
  final OperationId operationId;
  final Revision revision;
  final PurchaseQuantity quantity;
}

/// Owns one dialog's draft and idempotent submission, independently of tab state.
class PurchaseController extends ChangeNotifier {
  PurchaseController({
    required this.awardId,
    required this.watchShop,
    required this.economy,
    OperationId Function()? newOperationId,
  }) : _newOperationId = newOperationId ?? (() => OperationId(randomUuid())) {
    reload();
  }

  final ItemId awardId;
  final Stream<HomeData> Function() watchShop;
  final EconomyRepository economy;
  final OperationId Function() _newOperationId;
  StreamSubscription<HomeData>? _subscription;
  HomeData? data;
  Item? item;
  String input = '1';
  int quantity = 1;
  bool readFailed = false;
  bool busy = false;
  bool changed = false;
  String? error;
  EconomicState? completed;
  _PurchaseRequest? _request;
  bool _disposed = false;
  int _epoch = 0;

  bool get locked => busy || _request != null || completed != null;
  bool get validInput =>
      RegExp(r'^[0-9]+$').hasMatch(input) &&
      int.tryParse(input) != null &&
      int.parse(input) > 0;
  bool get available =>
      data != null &&
      !readFailed &&
      item?.archived == false &&
      item?.configuration is AwardConfiguration;
  PurchaseSummary? get summary =>
      available && validInput ? PurchaseSummary(data!, item!, quantity) : null;
  bool get canSubmit =>
      !busy &&
      completed == null &&
      (_request != null || summary?.canPurchase == true);
  bool get retrying => _request != null && !busy;

  void reload() {
    final epoch = ++_epoch;
    _subscription?.cancel();
    readFailed = false;
    if (_request == null) data = null;
    void failed() {
      if (_disposed || epoch != _epoch) return;
      readFailed = true;
      notifyListeners();
    }

    try {
      _subscription = watchShop().listen(
        (value) {
          if (_disposed || epoch != _epoch) return;
          // An uncertain reply may already have committed. Keep the confirmed
          // draft's original wallet/allowance preview until its operation replays.
          if (_request != null) {
            readFailed = false;
            notifyListeners();
            return;
          }
          final latest = value.item(awardId);
          if (item != null && latest?.revision != item!.revision) {
            changed = true;
          }
          item = latest;
          data = value;
          readFailed = false;
          notifyListeners();
        },
        onError: (Object e, StackTrace s) => failed(),
        onDone: failed,
      );
    } catch (_) {
      readFailed = true;
    }
    if (!_disposed) notifyListeners();
  }

  void setInput(String text) {
    if (locked) return;
    input = text;
    if (validInput) quantity = int.parse(text);
    error = null;
    notifyListeners();
  }

  void selectQuantity(int value) => setInput('${math.max(1, value)}');

  Future<void> submit({
    required Revision? displayedRevision,
    required int displayedQuantity,
  }) async {
    if (!canSubmit) return;
    // A stream can advance between a painted button and its callback. Never
    // treat a tap on that older preview as consent to the newly arrived offer.
    if (_request == null &&
        (item?.revision != displayedRevision ||
            quantity != displayedQuantity)) {
      notifyListeners();
      return;
    }
    final request = _request ??= _PurchaseRequest(
      _newOperationId(),
      item!.revision,
      PurchaseQuantity(quantity),
    );
    busy = true;
    error = null;
    notifyListeners();
    Result<EconomicState> result;
    try {
      result = await economy.redeemAward(
        operationId: request.operationId,
        awardId: awardId,
        expectedRevision: request.revision,
        quantity: request.quantity,
      );
    } catch (_) {
      result = const Failure(StorageUnavailable(retryable: true));
    }
    if (_disposed) return;
    busy = false;
    switch (result) {
      case Success<EconomicState>(:final value):
        completed = value;
      case Failure<EconomicState>(:final error):
        this.error = switch (error) {
          StaleRevision() => 'This Award changed. Review the updated purchase. Nothing was spent.',
          InsufficientFunds() => 'Your wallet changed. Choose an affordable quantity. Nothing was spent.',
          NumericOverflow() =>
            'This purchase exceeds the allowance limit. Choose fewer packs.',
          NotFound() ||
          InvalidInput() => 'This Award is no longer available for purchase.',
          _ =>
            'Could not confirm the purchase. Retry this same purchase safely.',
        };
        if (error is! StorageUnavailable) {
          _request = null;
          if (error is StaleRevision) changed = true;
          reload();
        }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _subscription?.cancel();
    super.dispose();
  }
}
