import Foundation
import Flutter

/// Native PDF import bridge. Printed-page conversion is performed by
/// NativeBookConversion.extractPdf through the `book_documents` channel; this
/// plugin reserves a dedicated channel for future direct PDF page access.
final class NativePdfImport: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = NativePdfImport()
    let channel = FlutterMethodChannel(
      name: "org.mewx.wenku8/native_pdf_import",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.publish(plugin)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}
