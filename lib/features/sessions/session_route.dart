import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import '../home/home_data.dart' show homeDuration;
import 'session_clock_view.dart';
import 'session_data.dart';

/// Compose with the app's shared store and SessionLifecycle.reconcile callback.
/// The lifecycle stays alive above navigation and owns deadline settlement.
class SessionRoute {
  const SessionRoute({
    required this.sessions,
    required this.clock,
    required this.watchSession,
    required this.reconcile,
    required this.operationId,
  });
  final SessionRepository sessions;
  final Clock clock;
  final Stream<SessionData?> Function(SessionId) watchSession;
  final Future<Result<SessionMutation?>> Function() reconcile;
  final OperationId Function() operationId;

  Future<void> open(
    BuildContext context,
    SessionId id,
    VoidCallback returnHome,
  ) {
    final navigator = Navigator.of(context);
    late MaterialPageRoute<void> route;
    var returned = false;
    route = MaterialPageRoute<void>(
      builder: (_) => SessionScreen(
        route: this,
        sessionId: id,
        onFinished: () {
          if (returned || !route.isActive) return;
          returned = true;
          returnHome();
          // Remove exactly this route if covered, retaining other modal drafts.
          if (route.isCurrent) {
            navigator.pop();
          } else {
            navigator.removeRoute(route);
          }
        },
      ),
    );
    return navigator.push(route);
  }
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.route,
    required this.sessionId,
    required this.onFinished,
  });
  final SessionRoute route;
  final SessionId sessionId;
  final VoidCallback onFinished;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  StreamSubscription<SessionData?>? _subscription;
  SessionData? _data;
  bool _failed = false;
  bool _busy = false;
  bool _recovering = true;
  bool _returned = false;
  String? _error;
  _SessionRequest? _retry;
  int _generation = 0;
  int _recoveryGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
    _recover();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recover();
    } else {
      _recoveryGeneration++;
      setState(() => _recovering = true);
    }
  }

  void _listen() {
    final generation = ++_generation;
    _subscription?.cancel();
    _failed = false;
    try {
      _subscription = widget.route
          .watchSession(widget.sessionId)
          .listen(
            (data) {
              if (!mounted || generation != _generation) return;
              setState(() {
                _data = data;
                _failed = data == null;
              });
              _finishIfCommitted();
            },
            onError: (Object _) {
              if (mounted && generation == _generation) {
                setState(() => _failed = true);
              }
            },
            onDone: () {
              if (mounted && generation == _generation) {
                setState(() => _failed = true);
              }
            },
          );
    } catch (_) {
      _failed = true;
    }
  }

  Future<bool> _recover() async {
    if (!mounted) return false;
    final generation = ++_recoveryGeneration;
    setState(() => _recovering = true);
    try {
      final result = await widget.route.reconcile();
      if (!mounted || generation != _recoveryGeneration) return false;
      if (result is Failure<SessionMutation?>) {
        setState(
          () => _error =
              'Could not recover the session. Retry before changing it.',
        );
        return false;
      }
      setState(() {
        _recovering = false;
        if (_retry == null) _error = null;
      });
      _finishIfCommitted();
      return true;
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not recover the session. Retry before changing it.',
        );
      }
      return false;
    }
  }

  void _finishIfCommitted() {
    if (_returned ||
        _recovering ||
        _busy ||
        _failed ||
        _data == null ||
        _data!.session.occupiesSlot) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _returned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFinished();
    });
  }

  Future<void> _command(SessionAction action) async {
    if (_busy || _failed || _data == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var request = _retry;
      if (request == null) {
        if (!await _recover()) return;
        // Reconciliation may have advanced the revision or completed the run.
        final read = await widget.route.sessions.getSession(widget.sessionId);
        if (!mounted) return;
        if (read case Success<Session?>(value: final current?)) {
          if (!current.occupiesSlot) return;
          request = _SessionRequest(
            widget.route.operationId(),
            action,
            current.revision,
          );
        } else {
          setState(
            () => _error = 'Could not read the current session. Try again.',
          );
          return;
        }
      }
      _retry = request;
      final result = await switch (request.action) {
        SessionAction.pause => widget.route.sessions.pauseSession(
          operationId: request.operation,
          sessionId: widget.sessionId,
          expectedRevision: request.revision,
        ),
        SessionAction.resume => widget.route.sessions.resumeSession(
          operationId: request.operation,
          sessionId: widget.sessionId,
          expectedRevision: request.revision,
        ),
        SessionAction.end => widget.route.sessions.endSession(
          operationId: request.operation,
          sessionId: widget.sessionId,
          expectedRevision: request.revision,
        ),
        SessionAction.reconcile => throw StateError('Not a UI command'),
      };
      if (!mounted) return;
      setState(() {
        switch (result) {
          case Success<SessionMutation>():
            _retry = null;
          case Failure<SessionMutation>(:final error):
            _error = switch (error) {
              StorageUnavailable() =>
                'Could not save the session. Retry the same action.',
              StaleRevision() =>
                'The session changed. Review its current state and try again.',
              _ => 'This action is unavailable. Review the current session.',
            };
            if (error is! StorageUnavailable || !error.retryable) _retry = null;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the session. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _finishIfCommitted();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final quest = data?.session.itemSnapshot.type != ItemType.award;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(
            quest ? 'Quest session' : 'Reward session',
            style: TroveTokens.heading,
          ),
          actions: [
            IconButton(
              tooltip: 'Close session view',
              onPressed: _busy ? null : () => Navigator.maybePop(context),
              icon: const TroveIcon('close', size: 24),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_failed) ...[
                  const Text('Could not load this session.'),
                  TroveButton(
                    label: 'Retry loading',
                    onPressed: () {
                      setState(_listen);
                      _recover();
                    },
                  ),
                ] else if (data == null)
                  const Center(child: CircularProgressIndicator())
                else
                  SessionClockView(
                    session: data.session,
                    clock: widget.route.clock,
                    builder: (context, remaining, label) =>
                        _content(data, remaining, label),
                  ),
                if (_busy)
                  const LinearProgressIndicator(
                    key: ValueKey('session-command-progress'),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_error!)),
                  if (_retry != null)
                    TroveButton(
                      label: 'Retry action',
                      onPressed: _busy ? null : () => _command(_retry!.action),
                    ),
                  if (_recovering && _retry == null)
                    TroveButton(
                      label: 'Retry recovery',
                      onPressed: _busy ? null : _recover,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(SessionData data, int remaining, String label) {
    final session = data.session;
    final quest = session.itemSnapshot.type == ItemType.quest;
    final paused = session.status == SessionStatus.paused;
    final palette =
        ItemPalette.presets
            .where((p) => p.accent.toARGB32() == data.item.colorArgb)
            .firstOrNull ??
        ItemPalette.custom(Color(data.item.colorArgb));
    final elapsed = session.duration.value - remaining;
    final enabled =
        !_busy && !_recovering && _retry == null && session.occupiesSlot;
    final validTime = label != 'Time unavailable' && label != 'Updating…';
    CurrencyAmounts? earnings;
    try {
      earnings = validTime && !_recovering
          ? data.earningsAt(remaining)
          : data.earned;
    } on DomainError {
      /* Display committed amounts until settlement can be retried. */
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ItemIcon(iconKey: data.item.iconKey, palette: palette),
        ),
        const SizedBox(height: 24),
        Text(
          data.item.name,
          textAlign: TextAlign.center,
          style: TroveTokens.title,
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final large = MediaQuery.textScalerOf(context).scale(14) > 20;
            final size = math.min(294.0, constraints.maxWidth);
            final countdown = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _recovering ? 'Recovering…' : label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: large || label.length > 8 ? 28 : 64,
                    fontWeight: FontWeight.w800,
                    height: 1.125,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  paused
                      ? 'Session paused'
                      : remaining == 0
                      ? 'Finishing…'
                      : 'of ${homeDuration(session.duration.value)}',
                  textAlign: TextAlign.center,
                ),
              ],
            );
            return Center(
              child: large
                  ? Column(
                      children: [
                        countdown,
                        const SizedBox(height: 20),
                        LinearProgressIndicator(
                          value: remaining / session.duration.value,
                          color: palette.accent,
                          backgroundColor: palette.surface,
                          semanticsLabel: 'Session time remaining',
                        ),
                      ],
                    )
                  : SizedBox(
                      width: size,
                      height: size,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: size - 12,
                            height: size - 12,
                            child: CircularProgressIndicator(
                              value: remaining / session.duration.value,
                              strokeWidth: 12,
                              color: palette.accent,
                              backgroundColor: palette.surface,
                              semanticsLabel: 'Session time remaining',
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: countdown,
                          ),
                        ],
                      ),
                    ),
            );
          },
        ),
        const SizedBox(height: 24),
        if (quest) ...[
          WalletDisplay(
            coins: (earnings ?? data.earned).coins.units,
            gems: (earnings ?? data.earned).gems.units,
          ),
          const SizedBox(height: 8),
          Text(
            !validTime || _recovering
                ? 'Session earnings · updating time'
                : 'Earned this session',
            textAlign: TextAlign.center,
            style: TroveTokens.caption,
          ),
        ] else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Text(
                  '${homeDuration(elapsed)} enjoyed · ${homeDuration(remaining)} left in this run',
                  textAlign: TextAlign.center,
                  style: TroveTokens.label,
                ),
                if (data.award?.budget case final budget?)
                  Text('$budget budget remains', textAlign: TextAlign.center),
              ],
            ),
          ),
        const SizedBox(height: 24),
        TroveButton(
          label: paused ? 'Resume session' : 'Pause session',
          onPressed: enabled && remaining > 0
              ? () => _command(
                  paused ? SessionAction.resume : SessionAction.pause,
                )
              : null,
        ),
        const SizedBox(height: 8),
        TroveButton(
          label: quest ? 'End & keep earnings' : 'End & keep remaining time',
          secondary: true,
          onPressed: enabled ? () => _command(SessionAction.end) : null,
        ),
        const SizedBox(height: 16),
        Text(
          paused
              ? 'Paused. No time or currency changes.'
              : quest
              ? 'Your earnings grow with active time.'
              : 'Unused time stays in My Trove.',
          textAlign: TextAlign.center,
          style: TroveTokens.caption,
        ),
        const SizedBox(height: 12),
        const Text(
          'Close this view to visit Home, Shop or Stats. Your session stays active.',
          textAlign: TextAlign.center,
          style: TroveTokens.caption,
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _SessionRequest {
  const _SessionRequest(this.operation, this.action, this.revision);
  final OperationId operation;
  final SessionAction action;
  final Revision revision;
}
