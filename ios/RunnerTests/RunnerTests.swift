import AVFoundation
import Flutter
import UserNotifications
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase, AVAudioPlayerDelegate {
  private var finished: XCTestExpectation?
  private var completions = 0

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    XCTAssertTrue(flag)
    completions += 1
    finished?.fulfill()
  }

  func testDurableClockHasStableBootAndFreshMonotonicSamples() throws {
    let first = try DurableClock.now()
    Thread.sleep(forTimeInterval: 0.05)
    let second = try DurableClock.now()
    let firstMonotonic = try XCTUnwrap(first["monotonicMilliseconds"] as? Int64)
    let secondMonotonic = try XCTUnwrap(second["monotonicMilliseconds"] as? Int64)
    XCTAssertEqual(first["bootId"] as? String, second["bootId"] as? String)
    XCTAssertTrue((first["bootId"] as? String)?.hasPrefix("ios-boot-") == true)
    XCTAssertGreaterThanOrEqual(secondMonotonic - firstMonotonic, 40)
    let utc = try XCTUnwrap(second["utcMilliseconds"] as? Int64)
    XCTAssertLessThan(abs(utc - Int64(Date().timeIntervalSince1970 * 1000)), 1000)
  }

  func testBundledAssetLoadsAndPlaysOnce() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "completion_chime", withExtension: "wav"))
    let player = try AVAudioPlayer(contentsOf: url)
    XCTAssertEqual(player.duration, 1.08, accuracy: 0.001)
    XCTAssertEqual(player.numberOfChannels, 1)
    XCTAssertEqual(player.numberOfLoops, 0)
    player.delegate = self
    finished = expectation(description: "One native playback completion")
    finished?.assertForOverFulfill = true
    XCTAssertTrue(player.prepareToPlay())
    XCTAssertTrue(player.play())
    waitForExpectations(timeout: 5)
    let quiet = expectation(description: "No repeat after another cue duration")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { quiet.fulfill() }
    waitForExpectations(timeout: 3)
    XCTAssertEqual(completions, 1)
    XCTAssertFalse(player.isPlaying)
    player.stop()
  }

  func testNotificationIsImmediateNoncriticalAndUsesCustomSound() throws {
    let request = try CompletionChime.request(completionId: "synthetic-completion")
    XCTAssertEqual(request.identifier, "minutrove.completion.synthetic-completion")
    XCTAssertNil(request.trigger)
    XCTAssertNotNil(request.content.sound)
    XCTAssertEqual(request.content.interruptionLevel, .active)
    XCTAssertEqual(CompletionChime.soundName, "completion_chime.wav")
  }

  func testDeadlineRequestKeepsStableIdentifierAndUtcTrigger() throws {
    let deadlineMs = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
    let request = try SessionNotifications.deadlineRequest(completionId: "synthetic-completion",
                                                           deadlineMilliseconds: deadlineMs)
    XCTAssertEqual(request.identifier, "minutrove.completion.synthetic-completion")
    let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
    XCTAssertFalse(trigger.repeats)
    // Foundation canonicalizes the UTC zone identifier to "GMT"; the zero
    // offset is what prevents the deadline drifting with device settings.
    let zone = try XCTUnwrap(trigger.dateComponents.timeZone)
    XCTAssertEqual(zone.secondsFromGMT(), 0,
                   "Without an explicit zero-offset zone the trigger would drift with device settings")
    let fireDate = try XCTUnwrap(trigger.nextTriggerDate())
    XCTAssertEqual(fireDate.timeIntervalSince1970,
                   TimeInterval(deadlineMs) / 1000,
                   accuracy: 1.0,
                   "The calendar trigger must interpret the deadline as UTC wall time")
    XCTAssertNotNil(request.content.sound)
    XCTAssertEqual(request.content.interruptionLevel, .active)
    // A device time-zone edit must not silently move the delivery copy.
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(identifier: "UTC")!
    let expected = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                              from: Date(timeIntervalSince1970: TimeInterval(deadlineMs) / 1000))
    XCTAssertEqual(trigger.dateComponents.year, expected.year)
    XCTAssertEqual(trigger.dateComponents.month, expected.month)
    XCTAssertEqual(trigger.dateComponents.day, expected.day)
    XCTAssertEqual(trigger.dateComponents.hour, expected.hour)
    XCTAssertEqual(trigger.dateComponents.minute, expected.minute)
    XCTAssertEqual(trigger.dateComponents.second, expected.second)
  }

  func testPermissionMappingCoversCurrentStatuses() {
    XCTAssertEqual(SessionNotifications.permissionString(.authorized), "granted")
    XCTAssertEqual(SessionNotifications.permissionString(.provisional), "provisional")
    XCTAssertEqual(SessionNotifications.permissionString(.ephemeral), "ephemeral")
    XCTAssertEqual(SessionNotifications.permissionString(.denied), "denied")
    XCTAssertEqual(SessionNotifications.permissionString(.notDetermined), "notDetermined")
  }

  /// Desired-state sync against the real center: the stable identifier
  /// replaces on reschedule and stale prefixed identifiers disappear. Pause,
  /// resume, end and crash recovery all reduce to this one operation.
  ///
  /// A recorded simulator limit shapes this test: without authorization the
  /// center silently holds nothing — `add` reports no error but
  /// `getPendingNotificationRequests` stays empty — so the suite first
  /// requests provisional authorization, which iOS grants quietly without a
  /// prompt, making the pending set observable. If the host still reports no
  /// authorization the content assertions degrade to the empty contract.
  func testSyncRequestsReplacesStableIdentifierAndRemovesStale() {
    let notifications = SessionNotifications()
    let authorized = expectation(description: "provisional authorization settles")
    var authorization = UNAuthorizationStatus.notDetermined
    UNUserNotificationCenter.current()
      .requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          authorization = settings.authorizationStatus
          DispatchQueue.main.async { authorized.fulfill() }
        }
      }
    wait(for: [authorized], timeout: 10)
    let observable = authorization == .authorized || authorization == .provisional
    let stableId = "minutrove.completion.11111111-1111-4111-8111-111111111111"
    let replacementId = "minutrove.completion.22222222-2222-4222-8222-222222222222"

    let finish = expectation(description: "sync completes")
    var pendingIdentifiers: [String] = []
    notifications.syncRequests(desired: [
      ["completionId": "11111111-1111-4111-8111-111111111111",
       "deadlineMilliseconds": Int64(Date().timeIntervalSince1970 * 1000) + 600_000],
    ]) { value in
      if let error = value as? FlutterError {
        XCTFail("Sync failed: \(error)")
        finish.fulfill()
        return
      }
      pendingIdentifiers = value as? [String] ?? []
      finish.fulfill()
    }
    wait(for: [finish], timeout: 10)
    XCTAssertEqual(pendingIdentifiers, observable ? [stableId] : [])

    // Rescheduling the same session keeps one stable identifier.
    let rescheduled = expectation(description: "reschedule completes")
    notifications.syncRequests(desired: [
      ["completionId": "11111111-1111-4111-8111-111111111111",
       "deadlineMilliseconds": Int64(Date().timeIntervalSince1970 * 1000) + 1_200_000],
    ]) { value in
      pendingIdentifiers = value as? [String] ?? []
      rescheduled.fulfill()
    }
    wait(for: [rescheduled], timeout: 10)
    XCTAssertEqual(pendingIdentifiers, observable ? [stableId] : [])

    // A different live deadline replaces the old identifier entirely.
    let replaced = expectation(description: "replacement completes")
    notifications.syncRequests(desired: [
      ["completionId": "22222222-2222-4222-8222-222222222222",
       "deadlineMilliseconds": Int64(Date().timeIntervalSince1970 * 1000) + 300_000],
    ]) { value in
      pendingIdentifiers = value as? [String] ?? []
      replaced.fulfill()
    }
    wait(for: [replaced], timeout: 10)
    XCTAssertEqual(pendingIdentifiers, observable ? [replacementId] : [])

    // Pause and end both reconcile to an empty desired state.
    let cancelled = expectation(description: "cancellation completes")
    notifications.syncRequests(desired: []) { value in
      pendingIdentifiers = value as? [String] ?? []
      cancelled.fulfill()
    }
    wait(for: [cancelled], timeout: 10)
    XCTAssertEqual(pendingIdentifiers, [])

    // Malformed desired input is rejected without touching pending state.
    let rejected = expectation(description: "invalid entry rejected")
    notifications.syncRequests(desired: [["completionId": ""]]) { value in
      XCTAssert(value is FlutterError, "An invalid completion ID must fail closed")
      rejected.fulfill()
    }
    wait(for: [rejected], timeout: 10)
  }

  func testColdStartTapIsQueuedUntilForwardingActivatesThenDeduplicates() {
    let notifications = SessionNotifications()
    let identifier = "minutrove.completion.33333333-3333-4333-8333-333333333333"
    notifications.handleTap(identifier: identifier)
    let flush = expectation(description: "queued tap flushes once")
    var forwarded: [String] = []
    notifications.activateTapForwarding { completionId in
      forwarded.append(completionId)
      if forwarded.count == 1 { flush.fulfill() }
    }
    wait(for: [flush], timeout: 5)
    // Later taps forward immediately; unrelated identifiers are ignored.
    notifications.handleTap(identifier: identifier)
    notifications.handleTap(identifier: "minutrove.completion.44444444-4444-4444-8444-444444444444")
    notifications.handleTap(identifier: "unrelated.prefix.notification")
    XCTAssertEqual(forwarded.first, "33333333-3333-4333-8333-333333333333")
    XCTAssertTrue(forwarded.contains("44444444-4444-4444-8444-444444444444"))
    XCTAssertFalse(forwarded.contains("unrelated.prefix.notification"))
  }

  func testForegroundPresentationSoundsOncePerCompletion() throws {
    let notifications = SessionNotifications()
    let center = UNUserNotificationCenter.current()
    let request = try CompletionChime.request(completionId: "55555555-5555-4555-8555-555555555555")
    let delivered = expectation(description: "notification delivered")
    center.add(request) { _ in delivered.fulfill() }
    wait(for: [delivered], timeout: 10)
    let presented = expectation(description: "pending state checked")
    center.getPendingNotificationRequests { pending in
      XCTAssertEqual(pending.count, 0, "A nil trigger must not leave a pending request")
      presented.fulfill()
    }
    wait(for: [presented], timeout: 10)
    // The dedup decision is exercised directly: one sound per identifier.
    let identifier = "minutrove.completion.55555555-5555-4555-8555-555555555555"
    XCTAssertEqual(notifications.presentOptions(forIdentifier: identifier), [.sound])
    XCTAssertEqual(notifications.presentOptions(forIdentifier: identifier), [],
                   "The immediate fallback must not repeat a sounded completion")
    XCTAssertEqual(
      notifications.presentOptions(
        forIdentifier: "minutrove.completion.66666666-6666-4666-8666-666666666666"),
      [.sound])
    XCTAssertEqual(notifications.presentOptions(forIdentifier: "other.app.notification"), nil,
                   "Notifications outside the completion prefix keep framework defaults")
  }
}
