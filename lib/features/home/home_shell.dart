import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import '../items/items.dart';
import 'home_data.dart';

/// Downstream screens receive stable identities and the same app dependencies.
/// Opening an expense never ends a session: the expense command applies the
/// explicit conflict choice atomically only when the user submits the form.
class HomeRoutes {
  const HomeRoutes({
    required this.shop,
    required this.stats,
    required this.openSession,
    required this.openExpense,
    this.openSettings,
  });
  final WidgetBuilder shop;
  final WidgetBuilder stats;
  final Future<void> Function(BuildContext, SessionId, VoidCallback returnHome)
  openSession;
  final Future<void> Function(
    BuildContext,
    Item,
    AwardBalance,
    SessionConflictChoice,
  )
  openExpense;
  final Future<void> Function(BuildContext)? openSettings;
}

/// Native navigation composition. Repositories, clock, and lifecycle ownership
/// live above this widget; changing tabs or dismissing a route cannot end them.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.watchHome,
    required this.editing,
    required this.sessions,
    required this.clock,
    required this.routes,
  });
  final Stream<HomeData> Function() watchHome;
  final ItemEditing editing;
  final SessionRepository sessions;
  final Clock clock;
  final HomeRoutes routes;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  StreamSubscription<HomeData>? _subscription;
  HomeData? _data;
  bool _loadFailed = false;
  bool _routing = false;
  int _selected = 0;
  int _gestureEpoch = 0;
  int _streamEpoch = 0;
  String? _actionError;
  _StartRequest? _retry;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.watchHome != widget.watchHome ||
        oldWidget.sessions != widget.sessions) {
      _listen();
    }
  }

  void _listen() {
    final epoch = ++_streamEpoch;
    _subscription?.cancel();
    _data = null;
    _loadFailed = false;
    _gestureEpoch++;
    _retry = null;
    _actionError = null;
    try {
      _subscription = widget.watchHome().listen(
        (data) {
          if (!mounted || epoch != _streamEpoch) return;
          setState(() {
            _data = data;
            _loadFailed = false;
          });
        },
        onError: (Object error, StackTrace stack) {
          if (!mounted || epoch != _streamEpoch) return;
          setState(() {
            _loadFailed = true;
            _gestureEpoch++;
          });
        },
        onDone: () {
          if (!mounted || epoch != _streamEpoch) return;
          setState(() {
            _loadFailed = true;
            _gestureEpoch++;
          });
        },
      );
    } catch (_) {
      _loadFailed = true;
    }
  }

  @override
  void dispose() {
    _streamEpoch++;
    _subscription?.cancel();
    super.dispose();
  }

  void _select(int index) => setState(() {
    _selected = index;
    _gestureEpoch++;
    _actionError = null;
    _retry = null;
  });

  bool get _ready => mounted && !_loadFailed && _data != null;

  Future<void> _route(Future<void> Function() action) async {
    if (!_ready || _routing) return;
    setState(() {
      _routing = true;
      _gestureEpoch++;
      _actionError = null;
      _retry = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _actionError = 'Could not open this activity. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  Future<void> _configure(ItemId? id) => _route(() async {
    final item = id == null ? null : _data!.item(id);
    if (id != null && item == null) return;
    await showItemEditor(context: context, editing: widget.editing, item: item);
  });

  Future<void> _openSession(SessionId id) =>
      widget.routes.openSession(context, id, () {
        if (mounted) _select(0);
      });

  Future<void> _activate(ItemId id, int epoch) async {
    if (epoch != _gestureEpoch ||
        _selected != 0 ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    await _route(() async {
      var item = _data!.item(id);
      if (item == null || !_data!.visible(item)) return;
      final active = _data!.activeSession;
      if (active?.itemSnapshot.id == id &&
          item.configuration is QuestConfiguration) {
        await _openSession(active!.id);
        return;
      }
      var expense = false;
      if (item.configuration case AwardConfiguration(
        :final timeGrant,
        :final budgetGrant,
      )) {
        if (timeGrant != null && budgetGrant != null) {
          final balance = _data!.awards[id]!;
          final choice = await showTroveDialog<bool>(
            context: context,
            title: item.name,
            builder: (dialogContext) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(homeItemSummary(item!, balance)),
                const SizedBox(height: 16),
                TroveButton(
                  label: 'Use time',
                  onPressed: (balance.time?.value ?? 0) > 0
                      ? () => Navigator.pop(dialogContext, false)
                      : null,
                ),
                const SizedBox(height: 8),
                TroveButton(
                  label: 'Record expense',
                  onPressed: (balance.budget?.minorUnits ?? 0) > 0
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                ),
                TroveButton(
                  label: 'Cancel',
                  secondary: true,
                  onPressed: () => Navigator.pop(dialogContext),
                ),
              ],
            ),
          );
          if (choice == null || !_ready) return;
          expense = choice;
        } else {
          expense = budgetGrant != null;
        }
      }
      // Resolve current type and revision after a choice dialog. Never interpret
      // a stale tile as a different action after a configuration edit.
      final current = _data!.item(id);
      if (current == null ||
          current.revision != item.revision ||
          !_data!.visible(current)) {
        _actionError =
            'This item changed. Select it again to use its current settings.';
        return;
      }
      item = current;
      var conflict = SessionConflictChoice.cancel;
      if (!mounted || !_ready) return;
      final occupying = _data!.activeSession;
      if (!expense && occupying?.itemSnapshot.id == id) {
        await _openSession(occupying!.id);
        return;
      }
      if (occupying != null) {
        final confirmed = await showTroveDialog<bool>(
          context: context,
          title: 'A session is already active',
          builder: (dialogContext) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${occupying.itemSnapshot.name} is ${occupying.status.name}. End it and continue with ${item!.name}?',
              ),
              const SizedBox(height: 16),
              TroveButton(
                label: 'End current session and continue',
                onPressed: () => Navigator.pop(dialogContext, true),
              ),
              TroveButton(
                label: 'Cancel',
                secondary: true,
                onPressed: () => Navigator.pop(dialogContext, false),
              ),
            ],
          ),
        );
        if (confirmed != true || !_ready) return;
        if (_data!.activeSession?.id != occupying.id) {
          _actionError = 'The active session changed. Select the item again.';
          return;
        }
        conflict = SessionConflictChoice.endCurrentAndContinue;
      }
      if (!mounted || !_ready) return;
      if (expense) {
        final balance = _data!.awards[id];
        if (balance == null || (balance.budget?.minorUnits ?? 0) == 0) return;
        await widget.routes.openExpense(context, item, balance, conflict);
      } else {
        await _start(
          _StartRequest(
            operation: widget.editing.operationId(),
            item: item,
            conflict: conflict,
            occupying: _data!.activeSession?.id,
          ),
        );
      }
    });
  }

  Future<void> _start(_StartRequest request) async {
    final generation = _streamEpoch;
    final result = await widget.sessions.startSession(
      operationId: request.operation,
      itemId: request.item.id,
      expectedItemRevision: request.item.revision,
      conflictChoice: request.conflict,
    );
    if (!mounted || generation != _streamEpoch) return;
    switch (result) {
      case Success<SessionMutation>(:final value):
        _retry = null;
        await _openSession(value.session.id);
      case Failure<SessionMutation>(:final error):
        _actionError = switch (error) {
          ActiveSessionConflict() => 'Another session is active. Select the item again to choose how to continue.',
          StaleRevision() =>
            'This item changed. Select it again to use its current settings.',
          AllowanceExceeded() =>
            'No time remains for this Award. Visit Shop to add more.',
          StorageUnavailable() => 'Could not start the session in local storage. Retry the same request.',
          _ => 'This item cannot start now. Check its configuration and try again.',
        };
        if (error is StorageUnavailable && error.retryable) _retry = request;
    }
  }

  Future<void> _retryStart() async {
    final request = _retry;
    if (request == null) return;
    await _route(() async {
      if (request.conflict == SessionConflictChoice.endCurrentAndContinue &&
          _data!.activeSession?.id != request.occupying &&
          _data!.activeSession?.id.value != request.operation.value) {
        _actionError = 'The active session changed. Select the item again.';
        return;
      }
      await _start(request);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final enabled = _ready && !_routing;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 24,
        title: const Text('Minutrove'),
        actions: [
          IconButton(
            tooltip: 'Add item',
            onPressed: enabled ? () => _configure(null) : null,
            icon: const TroveIcon('plus', size: 24),
          ),
          if (widget.routes.openSettings != null)
            IconButton(
              tooltip: 'Settings',
              onPressed: enabled
                  ? () => _route(() => widget.routes.openSettings!(context))
                  : null,
              icon: const TroveIcon('settings', size: 24),
            ),
        ],
      ),
      body: SafeArea(
        child: _loadFailed
            ? _message(
                'Could not load your items and balances.',
                action: TroveButton(
                  label: 'Retry loading',
                  onPressed: () => setState(_listen),
                ),
              )
            : data == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                    child: WalletDisplay(
                      coins: data.wallet.balances.coins.units,
                      gems: data.wallet.balances.gems.units,
                    ),
                  ),
                  if (_actionError != null)
                    Flexible(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              Semantics(
                                liveRegion: true,
                                child: Text(_actionError!),
                              ),
                              if (_retry != null)
                                TroveButton(
                                  label: 'Retry start',
                                  onPressed: enabled ? _retryStart : null,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    flex: 4,
                    child: IndexedStack(
                      index: _selected,
                      children: [
                        _home(data),
                        Builder(builder: widget.routes.shop),
                        Builder(builder: widget.routes.stats),
                      ],
                    ),
                  ),
                  if (data.activeSession case final session?)
                    CompactSessionSlot(
                      session: session,
                      clock: widget.clock,
                      onOpen: enabled
                          ? () => _route(() => _openSession(session.id))
                          : null,
                    ),
                ],
              ),
      ),
      bottomNavigationBar: TroveNavigationBar(
        selectedIndex: _selected,
        onDestinationSelected: _select,
      ),
    );
  }

  Widget _message(String text, {required Widget action}) =>
      SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text, style: TroveTokens.heading),
            const SizedBox(height: 20),
            action,
          ],
        ),
      );

  Widget _home(HomeData data) {
    final launchers = data.launchers;
    final epoch = _gestureEpoch;
    final knownGroups = data.groups.map((group) => group.id).toSet();
    return ListView(
      key: const PageStorageKey('home-scroll'),
      padding: const EdgeInsets.all(24),
      children: [
        if (launchers.isEmpty) ...[
          Text('Make time for what matters.', style: TroveTokens.heading),
          const SizedBox(height: 12),
          const Text(
            'Add a Quest to begin. Owned Awards appear here while an allowance remains.',
          ),
          const SizedBox(height: 20),
          TroveButton(
            label: 'Add your first item',
            onPressed: _routing ? null : () => _configure(null),
          ),
          const SizedBox(height: 8),
          TroveButton(
            label: 'Visit Shop',
            secondary: true,
            onPressed: () => _select(1),
          ),
        ],
        for (final group in <Group?>[...data.orderedGroups, null])
          if (launchers.any(
            (item) => group == null
                ? item.groupId == null || !knownGroups.contains(item.groupId)
                : item.groupId == group.id,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: ItemTileGroup(
                title: group?.name ?? 'Ungrouped',
                children: [
                  for (final item in launchers.where(
                    (item) => group == null
                        ? item.groupId == null ||
                              !knownGroups.contains(item.groupId)
                        : item.groupId == group.id,
                  ))
                    ItemTile(
                      key: ValueKey('${item.id.value}:$epoch'),
                      name: item.name,
                      kind: item.type == ItemType.quest
                          ? TileKind.quest
                          : TileKind.award,
                      iconKey: item.iconKey,
                      palette:
                          ItemPalette.presets
                              .where(
                                (palette) =>
                                    palette.accent.toARGB32() == item.colorArgb,
                              )
                              .firstOrNull ??
                          ItemPalette.custom(Color(item.colorArgb)),
                      summary: homeItemSummary(item, data.awards[item.id]),
                      onActivate: _routing || _selected != 0
                          ? null
                          : () => _activate(item.id, epoch),
                      onConfigure: () => _configure(item.id),
                    ),
                ],
              ),
            ),
        const SizedBox(height: 16),
        TroveButton(
          label: 'Edit layout · Configure items',
          secondary: true,
          onPressed: _routing
              ? null
              : () => _route(
                  () => showGroupManager(
                    context: context,
                    editing: widget.editing,
                  ),
                ),
        ),
      ],
    );
  }
}

class _StartRequest {
  const _StartRequest({
    required this.operation,
    required this.item,
    required this.conflict,
    required this.occupying,
  });
  final OperationId operation;
  final Item item;
  final SessionConflictChoice conflict;
  final SessionId? occupying;
}

class CompactSessionSlot extends StatefulWidget {
  const CompactSessionSlot({
    super.key,
    required this.session,
    required this.clock,
    required this.onOpen,
  });
  final Session session;
  final Clock clock;
  final VoidCallback? onOpen;
  @override
  State<CompactSessionSlot> createState() => _CompactSessionSlotState();
}

class _CompactSessionSlotState extends State<CompactSessionSlot> {
  late final Timer _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });
  @override
  void initState() {
    super.initState();
    _ticker;
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final remaining = remainingSessionTime(session, widget.clock.now());
    final seconds = remaining ~/ 1000 + (remaining % 1000 == 0 ? 0 : 1);
    final countdown =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final status = session.status == SessionStatus.paused
        ? 'Paused'
        : remaining == 0
        ? 'Finishing'
        : 'Running';
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .24,
      ),
      child: SingleChildScrollView(
        child: SizedBox(
          width: double.infinity,
          child: CompactSessionBar(
            name: session.itemSnapshot.name,
            timeLabel: countdown,
            paused: session.status == SessionStatus.paused,
            statusLabel: status,
            onOpen: widget.onOpen,
          ),
        ),
      ),
    );
  }
}
