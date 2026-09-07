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
}
