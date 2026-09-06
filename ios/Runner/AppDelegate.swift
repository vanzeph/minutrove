import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
    if notification.request.identifier.hasPrefix(CompletionChime.identifierPrefix) {
      completionHandler([.sound])
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CompletionChime") else { return }
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
  }
}
