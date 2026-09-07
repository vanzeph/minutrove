import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'home_data.dart';

/// Inject into HomeRoutes.openExpense using the app's shared repositories.
/// Consent is collected at submission, after validating the actual expense.
class AwardExpenseRoute {
  const AwardExpenseRoute({
    required this.economy,
    required this.watchHome,
    required this.readHome,
    required this.operationId,
  });
  final EconomyRepository economy;
  final Stream<HomeData> Function() watchHome;
  final Future<Result<HomeData>> Function() readHome;
  final OperationId Function() operationId;

  Future<void> open(
    BuildContext context,
    Item item,
    AwardBalance balance,
    SessionConflictChoice _,
  ) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AwardExpenseDialog(route: this, item: item),
  );
}

class AwardExpenseDialog extends StatefulWidget {
  const AwardExpenseDialog({
    super.key,
    required this.route,
    required this.item,
  });
  final AwardExpenseRoute route;
  final Item item;
  @override
  State<AwardExpenseDialog> createState() => _AwardExpenseDialogState();
}

class _AwardExpenseDialogState extends State<AwardExpenseDialog> {
  final _amount = TextEditingController();
  StreamSubscription<HomeData>? _subscription;
  HomeData? _data;
  bool _readFailed = false;
  bool _busy = false;
  String? _error;
  _ExpenseRequest? _retry;
  EconomicState? _receipt;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _subscription?.cancel();
    _readFailed = false;
    try {
      _subscription = widget.route.watchHome().listen(
        (data) {
          if (mounted) {
            setState(() {
              _data = data;
              _readFailed = false;
            });
          }
        },
        onError: (Object error, StackTrace stack) {
          if (mounted) setState(() => _readFailed = true);
        },
        onDone: () {
          if (mounted) setState(() => _readFailed = true);
        },
      );
    } catch (_) {
      _readFailed = true;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _amount.dispose();
    super.dispose();
  }

  BudgetAmount? _parse(BudgetAmount? available) {
    if (available == null) return null;
    try {
      final expense = BudgetAmount.parse(
        available.currency,
        _amount.text.trim(),
      );
      available.spend(expense);
      return expense;
    } on DomainError {
      return null;
    }
  }

  Future<HomeData?> _read() async {
    final result = await widget.route.readHome();
    if (!mounted) return null;
    switch (result) {
      case Success<HomeData>(:final value):
        setState(() {
          _data = value;
          _readFailed = false;
        });
        return value;
      case Failure<HomeData>():
        setState(() => _readFailed = true);
        return null;
    }
  }

  Future<void> _submit() async {
    if (_busy || _receipt != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var request = _retry;
      final data = await _read();
      if (data == null || !mounted) return;
      if (request == null) {
        final balance = data.awards[widget.item.id];
        final available = balance?.budget;
        final expense = _parse(available);
        if (expense == null || balance == null) {
          setState(() => _error = _validation(available));
          return;
        }
        var conflict = SessionConflictChoice.cancel;
        final active = data.activeSession;
        if (active != null) {
          final accepted = await showTroveDialog<bool>(
            context: context,
            title: 'A session is already active',
            builder: (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${active.itemSnapshot.name} is ${active.status.name}. End it and record $expense?',
                ),
                const SizedBox(height: 16),
                TroveButton(
                  label: 'End current session and continue',
                  onPressed: () => Navigator.pop(context, true),
                ),
                TroveButton(
                  label: 'Cancel',
                  secondary: true,
                  onPressed: () => Navigator.pop(context, false),
                ),
              ],
            ),
          );
          if (accepted != true || !mounted) return;
          final refreshed = await _read();
          if (refreshed == null) return;
          if (refreshed.activeSession?.id != active.id) {
            setState(
              () => _error =
                  'The active session changed. Review and submit again.',
            );
            return;
          }
          if (refreshed.awards[widget.item.id]?.revision != balance.revision) {
            setState(
              () => _error = 'Your allowance changed. Review the remaining budget and submit again.',
            );
            return;
          }
          conflict = SessionConflictChoice.endCurrentAndContinue;
        }
        request = _ExpenseRequest(
          widget.route.operationId(),
          balance.revision,
          expense,
          conflict,
          active?.id,
        );
      } else if (request.conflict ==
              SessionConflictChoice.endCurrentAndContinue &&
          data.activeSession != null &&
          data.activeSession!.id != request.active) {
        // A retry cannot carry consent to end a newly occupied slot.
        setState(() {
          _error = 'Another session is active. Finish it before retrying this expense.';
        });
        return;
      }
      // Freeze every argument across ambiguous storage failures and retries.
      _retry = request;
      final result = await widget.route.economy.recordExpense(
        operationId: request.operation,
        awardId: widget.item.id,
        expectedBalanceRevision: request.revision,
        expense: request.expense,
        conflictChoice: request.conflict,
      );
      if (!mounted) return;
      setState(() {
        switch (result) {
          case Success<EconomicState>(:final value):
            _receipt = value;
            _retry = null;
          case Failure<EconomicState>(:final error):
            if (error is! StorageUnavailable || !error.retryable) _retry = null;
            _error = switch (error) {
              StaleRevision() => 'Your allowance changed. Review the remaining budget and submit again.',
              ActiveSessionConflict() =>
                'A session started. Submit again to choose how to continue.',
              AllowanceExceeded() =>
                'This expense exceeds your remaining budget. Edit the amount.',
              StorageUnavailable() => 'Could not record the expense in local storage. Retry the same expense.',
              _ => 'Could not record this expense. Check the amount and remaining allowance.',
            };
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'Could not confirm the expense. Retry the same expense.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _validation(BudgetAmount? budget) =>
      budget == null || budget.minorUnits == 0
      ? 'No budget remains for this Award. Visit Shop to add more.'
      : 'Enter more than ${BudgetAmount(budget.currency, 0)} and no more than $budget, with at most ${budget.currency.minorDigits} decimal places.';

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final balance = data?.awards[widget.item.id];
    final available = balance?.budget;
    final expense = _parse(available);
    final name = data?.item(widget.item.id)?.name ?? widget.item.name;
    final receipt = _receipt;
    final recorded = receipt?.awards
        .where((a) => a.awardId == widget.item.id)
        .firstOrNull;
    return PopScope(
      canPop: !_busy,
      child: AbsorbPointer(
        absorbing: _busy,
        child: TroveDialog(
          title: receipt == null ? 'Enjoy your $name' : 'Expense recorded',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (receipt != null) ...[
                Text(
                  '${recorded?.budget ?? available} stays in My Trove.',
                  style: TroveTokens.heading,
                ),
                if (recorded?.time case final time?)
                  Text('${homeDuration(time.value)} of time remains.'),
                if (recorded?.isExhausted == true)
                  const Text(
                    'All allowances are used. Your catalog definition and history are retained.',
                  ),
                const SizedBox(height: 20),
                TroveButton(
                  label: 'Done',
                  onPressed: () => Navigator.pop(context),
                ),
              ] else ...[
                if (data == null && !_readFailed)
                  const LinearProgressIndicator(),
                if (_readFailed) ...[
                  const Text(
                    'Could not load your remaining allowance. Your amount is kept.',
                  ),
                  TroveButton(
                    label: 'Retry loading',
                    onPressed: _busy ? null : () => setState(_listen),
                  ),
                ],
                if (available != null) Text('You have $available to spend.'),
                if (balance?.time case final time?)
                  Text(
                    '${homeDuration(time.value)} of time remains independent of this expense.',
                  ),
                const SizedBox(height: 20),
                TroveTextField(
                  label: 'Actual cost · ${available?.currency.code ?? ''}',
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  enabled: !_busy && _retry == null,
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: 20),
                if (expense != null && !_readFailed)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: ItemPalette.presets[3].surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Budget after this expense'),
                          Text(
                            '${available! - expense} stays in My Trove',
                            style: TroveTokens.label,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_error != null ||
                    (expense == null && _amount.text.isNotEmpty)) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(_error ?? _validation(available)),
                  ),
                ],
                const SizedBox(height: 20),
                TroveButton(
                  label: _busy
                      ? 'Recording…'
                      : _retry != null
                      ? 'Retry expense'
                      : expense != null
                      ? 'Record $expense'
                      : 'Record expense',
                  onPressed: _busy || _readFailed || data == null
                      ? null
                      : _submit,
                ),
                TroveButton(
                  label: 'Cancel',
                  secondary: true,
                  onPressed: _busy ? null : () => Navigator.pop(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpenseRequest {
  const _ExpenseRequest(
    this.operation,
    this.revision,
    this.expense,
    this.conflict,
    this.active,
  );
  final OperationId operation;
  final Revision revision;
  final BudgetAmount expense;
  final SessionConflictChoice conflict;
  final SessionId? active;
}
