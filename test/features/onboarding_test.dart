import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/settings/settings.dart';

import '../support/settings_fakes.dart';

void main() {
  late FakeSettingsRepository settings;
  late FakeNotificationScheduler notifications;
  var finished = 0;

  Future<void> pumpFlow(WidgetTester tester) async {
    await tester.pumpWidget(
      MinutroveApp(
        home: OnboardingFlow(
          settings: settings,
          notifications: notifications,
          onFinished: () => finished++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    settings = FakeSettingsRepository(
      AppSettings(
        revision: Revision(1),
        reportingZone: ReportingZone('Asia/Tokyo'),
      ),
    );
    notifications = FakeNotificationScheduler();
    finished = 0;
  });

  testWidgets('welcome explains the loop without hardcoded goals', (
    tester,
  ) async {
    await pumpFlow(tester);
    expect(find.text('Turn your time into treasure'), findsOneWidget);
    expect(
      find.textContaining('Create Quests that earn Coins and Gems'),
      findsOneWidget,
    );
    expect(find.textContaining('stays on this device'), findsOneWidget);
    // No sample items, goals, prices or durations are offered or created.
    for (final sample in [
      'Sample',
      'Work',
      'Gaming',
      'Reading',
      '0 coins',
      '30 minutes',
    ]) {
      expect(find.textContaining(sample), findsNothing);
    }
    expect(settings.saves, isEmpty);
  });

  testWidgets('skipping from the welcome step writes nothing', (tester) async {
    await pumpFlow(tester);
    await tester.tap(find.text('Skip setup'));
    await tester.pumpAndSettle();
    expect(finished, 1);
    expect(settings.saves, isEmpty);
    expect(notifications.requests, isEmpty);
    expect(settings.current.reportingZone.ianaName, 'Asia/Tokyo');
  });

  testWidgets('timezone step shows the stored zone and keeps it on continue', (
    tester,
  ) async {
    await pumpFlow(tester);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Your reporting day'), findsOneWidget);
    expect(find.text('Asia/Tokyo'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(settings.saves, isEmpty);
  });

  testWidgets('an explicitly changed zone is stored once on continue', (
    tester,
  ) async {
    await pumpFlow(tester);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Asia/Tokyo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Europe/Berlin');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Europe/Berlin').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save timezone and continue'));
    await tester.pumpAndSettle();
    expect(settings.saves, hasLength(1));
    expect(settings.saves.single.$3.ianaName, 'Europe/Berlin');
    expect(settings.current.reportingZone.ianaName, 'Europe/Berlin');
  });

  testWidgets('skipping from the timezone step keeps the stored zone', (
    tester,
  ) async {
    await pumpFlow(tester);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Asia/Tokyo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Europe/Berlin');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Europe/Berlin').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip setup'));
    await tester.pumpAndSettle();
    expect(finished, 1);
    expect(settings.saves, isEmpty);
    expect(settings.current.reportingZone.ianaName, 'Asia/Tokyo');
  });

  testWidgets('notifications step asks contextually and finishes', (
    tester,
  ) async {
    notifications.nextPermission = NotificationPermission.granted;
    await pumpFlow(tester);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Finish on your terms'), findsOneWidget);
    await tester.tap(find.text('Allow notifications'));
    await tester.pumpAndSettle();
    expect(notifications.requests, hasLength(1));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(finished, 1);
    expect(settings.saves, isEmpty);
  });

  testWidgets('a denied answer links to the system settings', (tester) async {
    notifications.status = NotificationPermission.denied;
    await pumpFlow(tester);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      find.text('Notifications are turned off for Minutrove.'),
      findsOneWidget,
    );
    expect(find.text('Allow notifications'), findsNothing);
    await tester.tap(find.text('Open system settings'));
    await tester.pumpAndSettle();
    expect(notifications.settingsRequests, hasLength(1));
  });

  testWidgets('done without any change writes nothing', (tester) async {
    await pumpFlow(tester);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(finished, 1);
    expect(settings.saves, isEmpty);
    expect(settings.current.reportingZone.ianaName, 'Asia/Tokyo');
  });
}
