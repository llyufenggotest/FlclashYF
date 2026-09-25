import Darwin
import Flutter
import UIKit

private enum SideloadCompatibilityLoader {
  private static var handle: UnsafeMutableRawPointer?

  static func loadIfPresent() {
    guard handle == nil,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else { return }
    let dylibURL = frameworksURL.appendingPathComponent(
      "Tg_@HelloWorld_1024.dylib"
    )
    guard FileManager.default.fileExists(atPath: dylibURL.path) else { return }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
    if handle == nil, let message = dlerror() {
      NSLog(
        "[sideload] compatibility dylib load failed: %s",
        String(cString: message)
      )
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SideloadCompatibilityLoader.loadIfPresent()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ServiceChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
