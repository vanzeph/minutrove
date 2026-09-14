import Flutter
import Foundation
import UIKit
import UserNotifications

/// Owns deadline notification scheduling, contextual permission handling and
/// notification tap forwarding for the iOS adapter behind the Dart
/// `NotificationScheduler` port.
///
/// Scheduling follows desired-state reconciliation: `syncRequests` replaces
/// the stable identifier for a live deadline and removes every stale prefixed
/// request that no persisted intent asks for. Replacement by identifier makes
/// pause/resume/end and crash recovery idempotent at the OS level.
///
/// Delivery still obeys system policy: authorization, the ringer/silent
/// switch, Focus and Low Power Mode decide audibility; `.active` interruption
/// never breaks through them. Settlement never depends on delivery.
final class SessionNotifications {
  static let channelName = "io.github.vanzeph.minutrove/notifications"

  /// One audible foreground presentation per completion, per process. A
  /// scheduled cue that already sounded suppresses the immediate fallback.
  private var soundedIdentifiers = Set<String>()

  /// A cold-start tap can arrive before the Dart handler exists. Keep the
  /// latest completion ID and flush it when forwarding activates.
  private var queuedTapCompletionId: String?
  private var tapForwarder: ((String) -> Void)?

  // MARK: Request construction

  /// One calendar trigger, fully specified in UTC so a device time-zone or
  /// clock edit cannot silently move the deadline copy. Non-repeating.
  static func deadlineRequest(completionId: String,
                              deadlineMilliseconds: Int64) throws -> UNNotificationRequest {
    guard !completionId.isEmpty, completionId.count <= 128 else {
      throw NSError(domain: "MinutroveNotifications", code: 2)
    }
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    let date = Date(timeIntervalSince1970: TimeInterval(deadlineMilliseconds) / 1000)
    var components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                from: date)
    // Without an explicit time zone, UNCalendarNotificationTrigger interprets
    // the fields in the device's current zone and the deadline would drift.
    components.timeZone = TimeZone(identifier: "UTC")
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    return UNNotificationRequest(identifier: CompletionChime.identifierPrefix + completionId,
                                 content: try CompletionChime.makeContent(),
                                 trigger: trigger)
  }

  /// Provisional and ephemeral statuses still deliver notifications; the Dart
  /// port maps them to granted and leaves audibility to the sound setting.
  static func permissionString(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
  }

  // MARK: Channel operations

  func permission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        result(SessionNotifications.permissionString(settings.authorizationStatus))
      }
    }
  }

  /// Contextual prompt. If a decision already exists, iOS answers without
  /// prompting; there is no second question on a later call.
  func requestPermission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      (_, _) in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          result(SessionNotifications.permissionString(settings.authorizationStatus))
        }
      }
    }
  }

  /// Removes stale prefixed requests, adds or replaces the desired ones and
  /// answers with the pending prefixed identifiers after the sync.
  func syncRequests(desired: [[String: Any]], result: @escaping FlutterResult) {
    var wanted = [String: Int64]()
    for entry in desired {
      guard let completionId = entry["completionId"] as? String,
            !completionId.isEmpty, completionId.count <= 128,
            let deadline = entry["deadlineMilliseconds"] as? Int64, deadline > 0 else {
        DispatchQueue.main.async {
          result(FlutterError(code: "invalid_sync_request",
                              message: "Malformed desired notification", details: nil))
        }
        return
      }
      wanted[CompletionChime.identifierPrefix + completionId] = deadline
    }
    let center = UNUserNotificationCenter.current()
    center.getPendingNotificationRequests { requests in
      let stale = requests.map { $0.identifier }
        .filter { $0.hasPrefix(CompletionChime.identifierPrefix) && wanted[$0] == nil }
      if !stale.isEmpty {
        center.removePendingNotificationRequests(withIdentifiers: stale)
      }
      let group = DispatchGroup()
      var firstAddError: Error?
      for (identifier, deadline) in wanted {
        let completionId = String(identifier.dropFirst(CompletionChime.identifierPrefix.count))
        group.enter()
        do {
          let request = try SessionNotifications.deadlineRequest(
            completionId: completionId, deadlineMilliseconds: deadline)
          center.add(request) { error in
            if error != nil, firstAddError == nil { firstAddError = error }
            group.leave()
          }
        } catch {
          if firstAddError == nil { firstAddError = error }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        if let addError = firstAddError {
          result(FlutterError(code: "notification_sync_failed",
                              message: "\(addError.localizedDescription)", details: nil))
          return
        }
        center.getPendingNotificationRequests { updated in
          let pending = updated.map { $0.identifier }
            .filter { $0.hasPrefix(CompletionChime.identifierPrefix) }
          DispatchQueue.main.async { result(pending) }
        }
      }
    }
  }

  func openSettings(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(FlutterError(code: "settings_unavailable",
                            message: "No settings URL", details: nil))
        return
      }
      UIApplication.shared.open(url) { _ in
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  // MARK: Tap forwarding and foreground presentation

  /// Activates Dart-side forwarding and flushes a queued cold-start tap.
  func activateTapForwarding(_ forwarder: @escaping (String) -> Void) {
    tapForwarder = forwarder
    if let queued = queuedTapCompletionId {
      queuedTapCompletionId = nil
      forwarder(queued)
    }
  }

  /// Called by the app delegate when the user opens the app from a
  /// completion notification. The system already removed the tapped item.
  func handleTap(identifier: String) {
    guard identifier.hasPrefix(CompletionChime.identifierPrefix) else { return }
    let completionId = String(identifier.dropFirst(CompletionChime.identifierPrefix.count))
    if let forwarder = tapForwarder {
      forwarder(completionId)
    } else {
      queuedTapCompletionId = completionId
    }
  }

  /// Sound-only foreground presentation for completion notifications, at most
  /// once per completion in this process. Other notifications keep the
  /// framework default handled by the superclass.
  func presentOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
    presentOptions(forIdentifier: notification.request.identifier)
  }

  func presentOptions(forIdentifier identifier: String) -> UNNotificationPresentationOptions? {
    guard identifier.hasPrefix(CompletionChime.identifierPrefix) else { return nil }
    if soundedIdentifiers.contains(identifier) { return [] }
    soundedIdentifiers.insert(identifier)
    return [.sound]
  }
}
