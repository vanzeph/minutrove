import Flutter
import UserNotifications

/// Uses normal notification policy, including silent mode and Focus. No critical
/// or time-sensitive interruption level, background audio, or permission prompt.
final class CompletionChime {
  static let soundName = "completion_chime.wav"
  static let identifierPrefix = "minutrove.completion."

  static func request(completionId: String) throws -> UNNotificationRequest {
    guard Bundle.main.url(forResource: "completion_chime", withExtension: "wav") != nil else {
      throw NSError(domain: "MinutroveChime", code: 1)
    }
    let content = UNMutableNotificationContent()
    content.title = "Session complete"
    content.body = "Your time is complete. Rest or begin again when ready."
    content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
    content.interruptionLevel = .active
    // A nil trigger is immediate, one-shot delivery. No repeating timer.
    return UNNotificationRequest(identifier: identifierPrefix + completionId,
                                 content: content, trigger: nil)
  }

  static func playOnce(completionId: String, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized,
            settings.soundSetting == .enabled else {
        DispatchQueue.main.async { result("suppressed") }
        return
      }
      do {
        let request = try request(completionId: completionId)
        center.add(request) { error in
          DispatchQueue.main.async {
            if error != nil {
              result(FlutterError(code: "chime_submission_failed",
                                  message: "Could not submit completion sound", details: nil))
            } else {
              result("submitted")
            }
          }
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "chime_asset_missing",
                              message: "Completion sound is unavailable", details: nil))
        }
      }
    }
  }
}
