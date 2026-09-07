import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/domain.dart';

String sessionCountdown(int milliseconds) {
  final seconds = milliseconds ~/ 1000 + (milliseconds % 1000 == 0 ? 0 : 1);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// A display sample never settles a session or announces completion.
class SessionClockView extends StatefulWidget {
  const SessionClockView({
    super.key,
    required this.session,
    required this.clock,
    required this.builder,
  });
  final Session session;
  final Clock clock;
  final Widget Function(BuildContext, int remaining, String label) builder;
  @override
  State<SessionClockView> createState() => _SessionClockViewState();
}

class _SessionClockViewState extends State<SessionClockView> {
  Timer? _ticker;
  ClockReading? _reading;
  bool _failed = false;
  bool _sampling = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(SessionClockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.session, oldWidget.session) ||
        widget.clock != oldWidget.clock) {
      _reset();
    }
  }

  void _reset() {
    _generation++;
    _ticker?.cancel();
    _reading = null;
    _failed = false;
    _sampling = false;
    if (widget.session.status == SessionStatus.running) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
      _sample();
    }
  }

  Future<void> _sample() async {
    if (_sampling) return;
    _sampling = true;
    final generation = _generation;
    try {
      final reading = await widget.clock.now();
      if (!mounted || generation != _generation) return;
      setState(() {
        _reading = reading;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
    } finally {
      if (generation == _generation) _sampling = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final remaining = remainingSessionMilliseconds(
      session,
      _reading ?? session.checkpoint,
    );
    return widget.builder(
      context,
      remaining,
      _failed
          ? 'Time unavailable'
          : session.status == SessionStatus.running && _reading == null
          ? 'Updating…'
          : sessionCountdown(remaining),
    );
  }
}
