import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let notifications = SessionNotifications()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if let options = notifications.presentOptions(for: notification) {
      completionHandler(options)
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    if identifier.hasPrefix(CompletionChime.identifierPrefix) {
      // The system removed the tapped notification; route the settled result.
      notifications.handleTap(identifier: identifier)
      completionHandler()
    } else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CompletionChime") else { return }
    let clockChannel = FlutterMethodChannel(name: "io.github.vanzeph.minutrove/clock",
                                            binaryMessenger: registrar.messenger())
    clockChannel.setMethodCallHandler { call, result in
      guard call.method == "now" else { result(FlutterMethodNotImplemented); return }
      do {
        result(try DurableClock.now())
      } catch {
        result(FlutterError(code: "clock_unavailable", message: "Could not sample system clock", details: nil))
      }
    }
    let channel = FlutterMethodChannel(name: "io.github.vanzeph.minutrove/completion_chime",
                                       binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "playOnce" else { result(FlutterMethodNotImplemented); return }
      guard let arguments = call.arguments as? [String: Any],
            let id = arguments["completionId"] as? String,
            !id.isEmpty, id.count <= 128 else {
        result(FlutterError(code: "invalid_completion_id", message: "A completion ID is required", details: nil))
        return
      }
      CompletionChime.playOnce(completionId: id, result: result)
    }
    let notificationChannel = FlutterMethodChannel(name: SessionNotifications.channelName,
                                                   binaryMessenger: registrar.messenger())
    notificationChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.handleNotificationCall(call, on: notificationChannel, result: result)
    }
  }

  private func handleNotificationCall(_ call: FlutterMethodCall,
                                      on channel: FlutterMethodChannel,
                                      result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "permission":
      notifications.permission(result: result)
    case "requestPermission":
      notifications.requestPermission(result: result)
    case "syncRequests":
      guard let desired = arguments?["desired"] as? [[String: Any]] else {
        result(FlutterError(code: "invalid_sync_request",
                            message: "Expected desired notifications", details: nil))
        return
      }
      notifications.syncRequests(desired: desired, result: result)
    case "openSettings":
      notifications.openSettings(result: result)
    case "activateTapForwarding":
      notifications.activateTapForwarding { completionId in
        DispatchQueue.main.async {
          channel.invokeMethod("onNotificationTap", arguments: ["completionId": completionId])
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
