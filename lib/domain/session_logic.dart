import 'ports.dart';
import 'records.dart';
import 'result.dart';
import 'values.dart';

enum SessionAction { pause, resume, end, reconcile }

/// Pure accounting projection. The adapter commits only [addedIntervals] as new
/// economic activity; the complete session retains the previously settled ones.
final class SessionProgress {
  const SessionProgress({
    required this.session,
    required this.addedIntervals,
    required this.clockDiscontinuity,
  });
  final Session session;
  final List<ActiveInterval> addedIntervals;

  /// Lets lifecycle adapters report bounded wall-time recovery without logging
  /// item names or amounts. Same-boot accounting always uses monotonic time.
  final bool clockDiscontinuity;
}

SessionProgress advanceSession({
  required Session session,
  required SessionAction action,
  required ClockReading now,
  required ReportingCalendar calendar,
}) {
  SessionProgress unchanged() => SessionProgress(
    session: session,
    addedIntervals: const [],
    clockDiscontinuity: false,
  );

  if (!session.occupiesSlot) {
    if (action == SessionAction.end || action == SessionAction.reconcile) {
      return unchanged();
    }
    throw const InvalidSessionTransition();
  }
  if (session.status == SessionStatus.paused &&
      (action == SessionAction.pause || action == SessionAction.reconcile)) {
    return unchanged();
  }
  if (session.status == SessionStatus.running &&
      action == SessionAction.resume) {
    return unchanged();
  }
  if (!calendar.supports(session.zone)) {
    throw const InvalidInput('reportingZone', 'Unsupported reporting zone');
  }

  final anchor = session.checkpoint;
  final sameBoot = now.bootId == anchor.bootId;
  var elapsed = 0;
  if (session.status == SessionStatus.running) {
    if (sameBoot && now.monotonic.value < anchor.monotonic.value) {
      throw const InvalidInput('clock', 'Monotonic clock moved backwards');
    }
    elapsed = sameBoot
        ? now.monotonic.value - anchor.monotonic.value
        : now.utc.difference(anchor.utc).inMilliseconds;
    elapsed = elapsed.clamp(0, session.duration.value - session.settled.value);
  }
  final added = _intervals(session, now, elapsed, calendar);
  final settled = session.settled + Milliseconds(elapsed);
  final status = settled == session.duration
      ? SessionStatus.completed
      : switch (action) {
          SessionAction.pause => SessionStatus.paused,
          SessionAction.end => SessionStatus.ended,
          SessionAction.resume ||
          SessionAction.reconcile => SessionStatus.running,
        };
  if (action == SessionAction.reconcile &&
      elapsed == 0 &&
      sameBoot &&
      now.utc == anchor.utc &&
      now.monotonic == anchor.monotonic) {
    return unchanged();
  }
  final discontinuity =
      !sameBoot ||
      (session.status == SessionStatus.running &&
          now.utc.difference(anchor.utc).inMilliseconds !=
              now.monotonic.value - anchor.monotonic.value);
  return SessionProgress(
    session: Session(
      id: session.id,
      revision: session.revision.next(),
      itemSnapshot: session.itemSnapshot,
      status: status,
      zone: session.zone,
      startedAt: session.startedAt,
      checkpoint: now,
      duration: session.duration,
      settled: settled,
      deadlineUtc: status == SessionStatus.running
          ? sessionDeadline(now.utc, session.duration - settled)
          : null,
      completionId: session.completionId,
      intervals: [...session.intervals, ...added],
    ),
    addedIntervals: List.unmodifiable(added),
    clockDiscontinuity: discontinuity,
  );
}

/// DateTime has a narrower range than durable integer durations. Reject an
/// unrepresentable deadline as typed input, without wrapping or partial writes.
DateTime sessionDeadline(DateTime utc, Milliseconds remaining) {
  final epoch =
      BigInt.from(utc.millisecondsSinceEpoch) + BigInt.from(remaining.value);
  if (epoch > BigInt.from(8640000000000000) ||
      epoch < BigInt.from(-8640000000000000)) {
    throw const NumericOverflow('deadline');
  }
  return DateTime.fromMillisecondsSinceEpoch(epoch.toInt(), isUtc: true);
}

List<ActiveInterval> _intervals(
  Session session,
  ClockReading now,
  int elapsed,
  ReportingCalendar calendar,
) {
  if (elapsed == 0) return const [];
  final anchor = session.checkpoint;
  // Allocate active time along the checkpoint's timeline. A device wall-clock
  // edit cannot change the quantity earned or introduce a negative interval.
  // Across boots this is explicitly a bounded wall-time estimate.
  ClockReading at(int offset) => ClockReading(
    utc: sessionDeadline(anchor.utc, Milliseconds(offset)),
    bootId: anchor.bootId,
    monotonic: Milliseconds(
      checkedInteger(BigInt.from(anchor.monotonic.value) + BigInt.from(offset)),
    ),
  );
  final result = <ActiveInterval>[];
  var offset = 0;
  while (offset < elapsed) {
    final start = at(offset);
    final assignment = calendar.assign(start.utc, session.zone);
    final midnight = calendar.nextMidnight(assignment);
    final untilMidnight = midnight.difference(start.utc).inMilliseconds;
    if (!midnight.isUtc || untilMidnight <= 0) {
      throw const InvalidInput('calendar', 'Expected a later UTC midnight');
    }
    final length = (elapsed - offset).clamp(0, untilMidnight);
    final end = at(offset + length);
    result.add(
      ActiveInterval(
        startedAt: start,
        endedAt: anchor.bootId == now.bootId || offset + length < elapsed
            ? end
            : ClockReading(
                utc: end.utc,
                bootId: now.bootId,
                monotonic: now.monotonic,
              ),
        active: Milliseconds(length),
        assignment: assignment,
      ),
    );
    offset += length;
  }
  return result;
}
