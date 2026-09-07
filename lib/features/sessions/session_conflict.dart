import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'session_clock_view.dart';

/// Consent only. The caller revalidates the occupying identity, then its
/// repository command settles the current session and the next action atomically.
Future<bool?> showSessionConflict({
  required BuildContext context,
  required Session session,
  required String nextAction,
}) => showTroveDialog<bool>(
  context: context,
  title: 'A session is already active',
  builder: (context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '${session.itemSnapshot.name} is ${session.status.name}${session.status == SessionStatus.paused ? ' with ${sessionCountdown(session.duration.value - session.settled.value)} left' : ''}. End it and $nextAction?',
      ),
      const SizedBox(height: 12),
      Text(
        session.itemSnapshot.type == ItemType.quest
            ? 'Ending keeps earnings from active time. Paused time earns nothing.'
            : 'Ending keeps unused time in My Trove. Paused time consumes nothing.',
      ),
      const SizedBox(height: 16),
      TroveButton(
        label: 'End current session and continue',
        onPressed: () => Navigator.pop(context, true),
      ),
      const SizedBox(height: 8),
      TroveButton(
        label: 'Cancel',
        secondary: true,
        onPressed: () => Navigator.pop(context, false),
      ),
    ],
  ),
);
