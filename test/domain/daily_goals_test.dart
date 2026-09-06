import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';

void main() {
  final quest = ItemId('00000000-0000-4000-8000-000000000001');
  final goal = DailyGoal(
    target: Milliseconds(1000),
    bonus: CurrencyAmounts(coins: MicroAmount(0), gems: MicroAmount(0)),
  );
  DailyGoalRevision revision(int id, int day, {bool disabled = false}) =>
      DailyGoalRevision(
        questId: quest,
        revision: Revision(id),
        effectiveFrom: DayKey(2026, 1, day),
        zone: ReportingZone('Etc/UTC'),
        goal: disabled ? null : goal,
      );

  test(
    'effective dates, same-day edits and disable retain the right revision',
    () {
      final revisions = [
        revision(4, 20, disabled: true),
        revision(2, 15),
        revision(3, 15),
        revision(1, 1),
      ];
      expect(effectiveDailyGoal(revisions, DayKey(2025, 12, 31)), isNull);
      expect(
        effectiveDailyGoal(revisions, DayKey(2026, 1, 14))!.revision.value,
        1,
      );
      expect(
        effectiveDailyGoal(revisions, DayKey(2026, 1, 15))!.revision.value,
        3,
      );
      expect(effectiveDailyGoal(revisions, DayKey(2026, 1, 20))!.goal, isNull);
    },
  );

  test('threshold uses active milliseconds without overflowing history', () {
    expect(
      dailyGoalCrossing(
        goal: goal,
        priorActive: BigInt.from(900),
        added: Milliseconds(99),
      ),
      isNull,
    );
    expect(
      dailyGoalCrossing(
        goal: goal,
        priorActive: BigInt.from(900),
        added: Milliseconds(100),
      ),
      100,
    );
    expect(
      dailyGoalCrossing(
        goal: goal,
        priorActive: BigInt.one << 100,
        added: Milliseconds(1),
      ),
      0,
    );
    expect(
      dailyGoalCrossing(
        goal: null,
        priorActive: BigInt.zero,
        added: Milliseconds(1000),
      ),
      isNull,
    );
    expect(
      dailyGoalCrossing(
        goal: goal,
        priorActive: BigInt.from(1000),
        added: Milliseconds(0),
      ),
      isNull,
    );
  });
}
