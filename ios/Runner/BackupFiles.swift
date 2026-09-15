import Flutter
import Foundation
import UniformTypeIdentifiers
import UIKit

/// Owns the OS file interactions behind the Dart `BackupFilePicker` and
/// `BackupFileSharer` interfaces: one `.minutrove` document pick for restore
/// and one share-sheet hand-off for export.
///
/// Both operations are user-driven UI, so an answer arrives only after the
/// user closes the presented sheet. Cancelling the picker answers `nil`;
/// nothing is read and nothing changes. Reading uses a coordinated file
/// access; bytes are answered once and never cached. Sharing writes the
/// immutable export to an OS-owned temporary location only for the hand-off.
final class BackupFiles {
  static let channelName = "io.github.vanzeph.minutrove/files"
  static let fileExtension = "minutrove"

  /// One in-flight operation at a time: a second request while a picker is
  /// presented is rejected instead of dropping the first answer.
  private var pendingPickerResult: FlutterResult?

  // MARK: Channel operations

  func pickBackup(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard self.pendingPickerResult == nil else {
        result(FlutterError(code: "pick_already_active",
                            message: "A file picker is already open", details: nil))
        return
      }
      guard let presenter = UIApplication.shared.keyWindowRootController else {
        result(FlutterError(code: "picker_unavailable",
                            message: "No presenter is available", details: nil))
        return
      }
      self.pendingPickerResult = result
      // Prefer the declared extension; fall back to generic data so a renamed
      // or not-yet-registered file can still be chosen and validated in Dart.
      let types: [UTType] = [UTType(filenameExtension: BackupFiles.fileExtension,
                                    conformingTo: .data) ?? .data, .data]
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
      picker.delegate = self
      picker.modalPresentationStyle = .pageSheet
      presenter.present(picker, animated: true)
    }
  }

  func shareBackup(fileName: String, bytes: FlutterStandardTypedData, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard !fileName.isEmpty, fileName.count <= 128,
            fileName.hasSuffix(".\(BackupFiles.fileExtension)"),
            !fileName.contains("/") else {
        result(FlutterError(code: "invalid_share_request",
                            message: "A .minutrove file name is required", details: nil))
        return
      }
      guard let presenter = UIApplication.shared.keyWindowRootController else {
        result(FlutterError(code: "share_unavailable",
                            message: "No presenter is available", details: nil))
        return
      }
      do {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try bytes.data.write(to: url, options: .atomic)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { (_, _, _, _) in
          try? FileManager.default.removeItem(at: url)
        }
        if let popover = controller.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = presenter.view.bounds.insetBy(dx: presenter.view.bounds.width / 4,
                                                              dy: presenter.view.bounds.height / 4)
        }
        presenter.present(controller, animated: true) {
          result(true)
        }
      } catch {
        result(FlutterError(code: "share_write_failed",
                            message: "Could not stage the backup for sharing", details: nil))
      }
    }
  }
}

extension BackupFiles: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPickerResult else { return }
    pendingPickerResult = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    let coordinated = NSFileCoordinator()
    var bytes: Data?
    var coordinateError: NSError?
    coordinated.coordinate(readingItemAt: url, options: .forUploading,
                           error: &coordinateError) { readingURL in
      bytes = try? Data(contentsOf: readingURL)
    }
    if let bytes {
      result(FlutterStandardTypedData(bytes: bytes))
    } else {
      result(FlutterError(code: "pick_read_failed",
                          message: "Could not read the selected file", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let result = pendingPickerResult else { return }
    pendingPickerResult = nil
    result(nil)
  }
}

extension UIApplication {
  /// The controller that currently presents the app's visible interface; the
  /// Flutter view controller when no custom sheet is above it.
  var keyWindowRootController: UIViewController? {
    connectedScenes.compactMap { scene -> UIViewController? in
      guard let windowScene = scene as? UIWindowScene,
            scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
      else { return nil }
      return windowScene.keyWindow?.rootViewController
    }.first ?? connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
  }
}
