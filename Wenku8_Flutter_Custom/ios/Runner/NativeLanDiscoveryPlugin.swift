import Foundation
import Flutter
import Network

/// LAN peer discovery registration point. Device discovery itself is driven
/// by the shared Dart handover policy; this plugin publishes the channel so a
/// future native implementation can be added without changing AppDelegate.
final class NativeLanDiscoveryPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = NativeLanDiscoveryPlugin()
    let channel = FlutterMethodChannel(
      name: "org.mewx.wenku8/lan_discovery",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.publish(plugin)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}
