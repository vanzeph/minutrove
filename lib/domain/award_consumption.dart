import 'records.dart';

enum AwardConsumptionAction { useTime, recordExpense }

/// No action for exhaustion, one direct action for one usable dimension, or
/// a choice for combined allowances. Reading routes never settles a session.
List<AwardConsumptionAction> awardConsumptionActions(AwardBalance balance) =>
    List.unmodifiable([
      if ((balance.time?.value ?? 0) > 0) AwardConsumptionAction.useTime,
      if ((balance.budget?.minorUnits ?? 0) > 0)
        AwardConsumptionAction.recordExpense,
    ]);
