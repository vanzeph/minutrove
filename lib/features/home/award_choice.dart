import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'home_data.dart';

enum AwardUseChoice { time, expense, configure }

Future<AwardUseChoice?> showAwardUseChoice({
  required BuildContext context,
  required Item item,
  required Stream<HomeData> updates,
}) => showTroveDialog<AwardUseChoice>(
  context: context,
  title: 'Enjoy your ${item.name}',
  builder: (context) => StreamBuilder<HomeData>(
    stream: updates,
    builder: (context, snapshot) {
      final data = snapshot.data;
      final balance = data?.awards[item.id];
      final valid =
          snapshot.hasData &&
          !snapshot.hasError &&
          snapshot.connectionState != ConnectionState.done &&
          data?.item(item.id)?.revision == item.revision;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Your time and spending allowances are independent.'),
          const SizedBox(height: 16),
          if (!snapshot.hasData &&
              !snapshot.hasError &&
              snapshot.connectionState != ConnectionState.done)
            const LinearProgressIndicator(),
          if (valid) ...[
            if (balance?.time case final time?)
              Text(
                '${homeDuration(time.value)} available',
                style: TroveTokens.heading,
              ),
            if (balance?.budget case final budget?)
              Text('$budget available', style: TroveTokens.heading),
          ] else if (snapshot.hasError || snapshot.hasData)
            const Text(
              'Your item or allowance changed or could not be loaded. Close and open it again.',
            ),
          const SizedBox(height: 16),
          TroveButton(
            label: 'Use time',
            onPressed: valid && (balance?.time?.value ?? 0) > 0
                ? () => Navigator.pop(context, AwardUseChoice.time)
                : null,
          ),
          const SizedBox(height: 8),
          TroveButton(
            label: 'Record expense',
            secondary: true,
            onPressed: valid && (balance?.budget?.minorUnits ?? 0) > 0
                ? () => Navigator.pop(context, AwardUseChoice.expense)
                : null,
          ),
          if (valid && (balance?.time?.value ?? 0) == 0)
            const Text('No time remains.'),
          if (valid && (balance?.budget?.minorUnits ?? 0) == 0)
            const Text('No budget remains.'),
          TroveButton(
            label: 'Configure ${item.name}',
            secondary: true,
            onPressed: valid
                ? () => Navigator.pop(context, AwardUseChoice.configure)
                : null,
          ),
          TroveButton(
            label: 'Cancel',
            secondary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    },
  ),
);
