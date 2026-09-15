import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/data/reporting_calendar.dart';
import 'package:minutrove/platform/clock/device_zone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.vanzeph.minutrove/clock');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'a known IANA identifier becomes the first-run reporting zone',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => 'Asia/Tokyo');
      expect(
        (await deviceReportingZone(calendar: IanaReportingCalendar())).ianaName,
        'Asia/Tokyo',
      );
    },
  );

  test('a manual GMT offset is not an IANA location and falls back', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'GMT+08:00');
    expect(
      (await deviceReportingZone(calendar: IanaReportingCalendar())).ianaName,
      'Etc/UTC',
    );
  });

  test('a missing native answer falls back without failing startup', () async {
    for (final answer in [null, '', 'not-a-real-zone-abcdef']) {
      messenger.setMockMethodCallHandler(channel, (_) async => answer);
      expect(
        (await deviceReportingZone(calendar: IanaReportingCalendar())).ianaName,
        'Etc/UTC',
      );
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'clock_unavailable'),
    );
    expect(
      (await deviceReportingZone(calendar: IanaReportingCalendar())).ianaName,
      'Etc/UTC',
    );
  });
}
