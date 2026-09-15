import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/app.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/features/settings/settings.dart';

import '../support/settings_fakes.dart';

void main() {
  group('SettingsScreen overview', () {
    testWidgets('states the local-only property and lists the entries', (
      tester,
    ) async {
      await tester.pumpWidget(
        MinutroveApp(
          home: SettingsScreen(
            settings: FakeSettingsRepository(
              AppSettings(
                revision: Revision(1),
                reportingZone: ReportingZone('Etc/UTC'),
              ),
            ),
            notifications: FakeNotificationScheduler(),
            backup: FakeBackupRepository(),
            picker: FakePicker(() => null),
            sharer: FakeSharer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your Minutrove'), findsOneWidget);
      expect(
        find.text(
          'Local to this device. Backups let you move your data manually.',
        ),
        findsOneWidget,
      );
      for (final entry in [
        'Backup & restore',
        'Reporting timezone',
        'Notifications & sound',
        'About & licenses',
      ]) {
        expect(find.text(entry), findsOneWidget);
      }
      expect(find.textContaining('sign in'), findsNothing);
      expect(find.textContaining('account'), findsNothing);
      expect(find.textContaining('cloud'), findsNothing);
    });

    testWidgets('navigation reaches each sub-screen and back changes nothing', (
      tester,
    ) async {
      final settings = FakeSettingsRepository(
        AppSettings(
          revision: Revision(1),
          reportingZone: ReportingZone('Etc/UTC'),
        ),
      );
      await tester.pumpWidget(
        MinutroveApp(
          home: SettingsScreen(
            settings: settings,
            notifications: FakeNotificationScheduler(),
            backup: FakeBackupRepository(),
            picker: FakePicker(() => null),
            sharer: FakeSharer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reporting timezone'));
      await tester.pumpAndSettle();
      expect(find.text('Your reporting day'), findsOneWidget);
      expect(find.text('Etc/UTC'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Your Minutrove'), findsOneWidget);

      await tester.tap(find.text('Notifications & sound'));
      await tester.pumpAndSettle();
      expect(find.text('Finish on your terms'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('About & licenses'));
      await tester.pumpAndSettle();
      expect(find.text('Made for your own time'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Backup & restore'));
      await tester.pumpAndSettle();
      expect(find.text('Keep a copy'), findsOneWidget);
      expect(settings.saves, isEmpty);
    });
  });

  group('TimezoneScreen', () {
    testWidgets('saves an explicitly changed zone through the repository', (
      tester,
    ) async {
      final settings = FakeSettingsRepository(
        AppSettings(
          revision: Revision(1),
          reportingZone: ReportingZone('Etc/UTC'),
        ),
      );
      await tester.pumpWidget(
        MinutroveApp(home: TimezoneScreen(settings: settings)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Etc/UTC'));
      await tester.pumpAndSettle();
      expect(find.text('Reporting timezone'), findsWidgets);
      await tester.enterText(find.byType(TextField), 'Asia/Tokyo');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Asia/Tokyo').last);
      await tester.pumpAndSettle();
      expect(find.text('Asia/Tokyo'), findsOneWidget);

      await tester.tap(find.text('Save timezone'));
      await tester.pumpAndSettle();
      expect(settings.saves, hasLength(1));
      expect(settings.saves.single.$3.ianaName, 'Asia/Tokyo');
      expect(settings.current.reportingZone.ianaName, 'Asia/Tokyo');
    });

    testWidgets('cancel leaves the stored zone unchanged without saving', (
      tester,
    ) async {
      final settings = FakeSettingsRepository(
        AppSettings(
          revision: Revision(1),
          reportingZone: ReportingZone('Etc/UTC'),
        ),
      );
      await tester.pumpWidget(
        MinutroveApp(home: TimezoneScreen(settings: settings)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.saves, isEmpty);
      expect(settings.current.reportingZone.ianaName, 'Etc/UTC');
    });

    testWidgets(
      'a stale revision surfaces a reload message and keeps editing',
      (tester) async {
        final settings = FakeSettingsRepository(
          AppSettings(
            revision: Revision(7),
            reportingZone: ReportingZone('Etc/UTC'),
          ),
        );
        await tester.pumpWidget(
          MinutroveApp(home: TimezoneScreen(settings: settings)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Etc/UTC'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Europe/Berlin');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Europe/Berlin').last);
        await tester.pumpAndSettle();
        // Simulate the concurrent edit that invalidates the loaded revision.
        settings.bumpRevision();
        await tester.tap(find.text('Save timezone'));
        await tester.pumpAndSettle();
        expect(find.textContaining('changed elsewhere'), findsOneWidget);
        expect(settings.saves, hasLength(1));
      },
    );
  });

  group('NotificationsScreen', () {
    testWidgets('granted status states notifications are on', (tester) async {
      await tester.pumpWidget(
        MinutroveApp(
          home: NotificationsScreen(
            notifications: FakeNotificationScheduler(
              status: NotificationPermission.granted,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notifications are on for Minutrove.'), findsOneWidget);
      expect(find.text('Allow notifications'), findsNothing);
    });

    testWidgets('notDetermined offers the contextual ask', (tester) async {
      final scheduler = FakeNotificationScheduler()
        ..nextPermission = NotificationPermission.granted;
      await tester.pumpWidget(
        MinutroveApp(home: NotificationsScreen(notifications: scheduler)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow notifications'));
      await tester.pumpAndSettle();
      expect(scheduler.requests, hasLength(1));
      expect(find.text('Notifications are on for Minutrove.'), findsOneWidget);
    });

    testWidgets('denied status links to the system settings', (tester) async {
      final scheduler = FakeNotificationScheduler(
        status: NotificationPermission.denied,
      );
      await tester.pumpWidget(
        MinutroveApp(home: NotificationsScreen(notifications: scheduler)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Notifications are turned off for Minutrove.'),
        findsOneWidget,
      );
      expect(find.text('Allow notifications'), findsNothing);
      await tester.tap(find.text('Open system settings'));
      await tester.pumpAndSettle();
      expect(scheduler.settingsRequests, hasLength(1));
    });
  });

  group('AboutScreen', () {
    testWidgets('carries license, notices, diagnostics and all help topics', (
      tester,
    ) async {
      await tester.pumpWidget(const MinutroveApp(home: AboutScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('App license'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('GNU Affero General Public License'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Local diagnostics'));
      await tester.pumpAndSettle();
      expect(find.textContaining('fixed event codes'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Help & how it works'));
      await tester.pumpAndSettle();
      for (final topic in [
        'Earning with a Quest',
        'Redeeming an Award',
        'Using an allowance',
        'Statistics',
        'Configuring items',
        'Backup and restore',
      ]) {
        expect(find.text(topic), findsOneWidget);
      }
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dependency & asset notices'));
      await tester.pumpAndSettle();
      expect(find.text('Minutrove'), findsWidgets);
      expect(find.text('Close'), findsNothing);
    });
  });
}
