import 'items.dart';
import 'values.dart';

int compareDays(DayKey a, DayKey b) {
  final year = a.year.compareTo(b.year);
  if (year != 0) return year;
  final month = a.month.compareTo(b.month);
  return month != 0 ? month : a.day.compareTo(b.day);
}

/// Dates are frozen local calendar keys. Changing reporting zone does not
/// reinterpret revisions or give a Quest a second achievement for that date.
/// A null goal is an effective disabling revision, not a missing revision.
DailyGoalRevision? effectiveDailyGoal(
  Iterable<DailyGoalRevision> revisions,
  DayKey day,
) {
  DailyGoalRevision? selected;
  for (final candidate in revisions) {
    if (compareDays(candidate.effectiveFrom, day) > 0) continue;
    final order = selected == null
        ? 1
        : compareDays(candidate.effectiveFrom, selected.effectiveFrom);
    if (order > 0 ||
        (order == 0 && candidate.revision.value > selected!.revision.value)) {
      selected = candidate;
    }
  }
  return selected;
}

/// Active milliseconds into this new interval at which an unpaid goal is met.
/// BigInt history totals cannot overflow even for a long-lived local database.
int? dailyGoalCrossing({
  required DailyGoal? goal,
  required BigInt priorActive,
  required Milliseconds added,
}) {
  if (goal == null || added.value == 0) return null;
  final remaining = BigInt.from(goal.target.value) - priorActive;
  if (remaining > BigInt.from(added.value)) return null;
  return remaining.isNegative ? 0 : remaining.toInt();
}
