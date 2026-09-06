import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/home/home_shell.dart';

import '../data/support.dart' as f;

class DeferredClock implements Clock {
  final requests = <Completer<ClockReading>>[];
  @override
  Future<ClockReading> now() {
    final value = Completer<ClockReading>();
    requests.add(value);
    return value.future;
  }
}

void main() {
  ClockReading reading(int monotonic) => ClockReading(
    utc: f.now,
    bootId: 'fixture-boot',
    monotonic: Milliseconds(monotonic),
  );
  Widget mount(Session session, Clock clock) => MaterialApp(
    home: Scaffold(
      body: CompactSessionSlot(session: session, clock: clock, onOpen: () {}),
    ),
  );

  testWidgets(
    'replaced session discards delayed samples and disposal ignores pending results',
    (tester) async {
      final clock = DeferredClock();
      await tester.pumpWidget(mount(f.session(f.quest()), clock));
      expect(find.textContaining('Updating'), findsOneWidget);
      await tester.pumpWidget(mount(f.session(f.quest(), revision: 2), clock));
      expect(clock.requests.length, 2);
      clock.requests[1].complete(reading(12000));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('0:49'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('|'),
      );
      clock.requests[0].complete(reading(999999));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('0:49'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('|'),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      clock.requests.last.completeError(
        const StorageUnavailable(retryable: true),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable time is visible, next sample recovers, pause never samples',
    (tester) async {
      final clock = DeferredClock();
      await tester.pumpWidget(mount(f.session(f.quest()), clock));
      clock.requests.single.completeError(
        const StorageUnavailable(retryable: true),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Time unavailable'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      clock.requests.last.complete(reading(12000));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('0:49'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('|'),
      );
      await tester.pumpWidget(
        mount(f.session(f.quest(), status: SessionStatus.paused), clock),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(clock.requests.length, 2);
      expect(find.textContaining('Paused'), findsOneWidget);
      expect(find.textContaining('0:50'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
