import 'dart:async';

import 'package:flutter/services.dart';

import '../../data/reporting_calendar.dart';
import '../../domain/domain.dart';

/// The IANA identifier of the device's current time zone, over the durable
/// clock channel. On Android a manually fixed offset reports as a `GMT±`
/// identifier, which is not an IANA location; callers validate the answer
/// against the reporting calendar and fall back themselves.
Future<String?> nativeDeviceTimeZone([
  MethodChannel channel = const MethodChannel(
    'io.github.vanzeph.minutrove/clock',
  ),
]) async {
  try {
    final value = await channel
        .invokeMethod<String>('deviceTimeZone')
        .timeout(const Duration(seconds: 2));
    if (value == null || value.isEmpty || value.length > 64) return null;
    return value;
  } catch (_) {
    // Without a reliable native answer the composition falls back to UTC and
    // onboarding lets the user correct the zone once before any activity.
    return null;
  }
}

/// Captures the reporting zone from the device for a first-run database.
/// A missing native handler, a transport failure, or an identifier the pinned
/// IANA database does not know (manual GMT offsets) resolves to `Etc/UTC`,
/// which onboarding then shows for an explicit one-time correction.
Future<ReportingZone> deviceReportingZone({
  IanaReportingCalendar? calendar,
  Future<String?> Function()? readNativeZone,
}) async {
  final identifier = await (readNativeZone ?? nativeDeviceTimeZone)();
  if (identifier != null) {
    final zone = ReportingZone(identifier);
    if ((calendar ?? IanaReportingCalendar()).supports(zone)) return zone;
  }
  return ReportingZone('Etc/UTC');
}
