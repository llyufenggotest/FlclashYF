import Darwin
import Flutter
import UIKit

private enum SideloadCompatibilityLoader {
  private static var handle: UnsafeMutableRawPointer?

  static func loadIfPresent() {
    SwitchDiagnostics.record("ipad_loader_before")
    defer { SwitchDiagnostics.record("ipad_loader_after", fields: ["loader_loaded": String(handle != nil)]) }
    guard handle == nil,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else { return }
    let dylibURL = frameworksURL.appendingPathComponent(
      "Tg_@HelloWorld_1024.dylib"
    )
    let exists = FileManager.default.fileExists(atPath: dylibURL.path)
    SwitchDiagnostics.record("ipad_loader_before", fields: ["loader_exists": String(exists)])
    guard exists else { return }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
    if handle == nil { NSLog("[sideload] compatibility dylib load failed") }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SideloadCompatibilityLoader.loadIfPresent()
    SwitchDiagnostics.recordRunnerLaunch()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    SwitchDiagnostics.record("app_memory_warning")
    super.applicationDidReceiveMemoryWarning(application)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    SwitchDiagnostics.recordRunnerTermination()
    super.applicationWillTerminate(application)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ServiceChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
