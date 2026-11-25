import Flutter
import UIKit
import audio_session
import device_info_plus
import flutter_secure_storage
import flutter_sound
import just_audio
import path_provider_foundation
import permission_handler_apple
import quick_actions_ios
import share_plus
import shared_preferences_foundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let maxPresetBytes = 4 * ((32_768 + 2) / 3)

  private var launchSettings: [String: String]? = {
    let field = "OMI_LOCAL_SERVER_PRESETS_B64"
    defer {
      unsetenv(field)
      unsetenv("OMI_LOCAL_MAC_URL")
      unsetenv("OMI_LOCAL_MAC_KEY")
    }
    guard let raw = getenv(field), strnlen(raw, AppDelegate.maxPresetBytes + 1) <= AppDelegate.maxPresetBytes,
          let encoded = String(validatingCString: raw), !encoded.isEmpty else { return nil }
    return ["server_presets_b64": encoded]
  }()

  // A trusted USB installer can hand off the same envelope without a debugger
  // connection. Caches are private to this app and excluded from iOS backups.
  private static func takeUSBPreset() -> [String: String]? {
    let files = FileManager.default
    guard let cache = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let url = cache.appendingPathComponent("omilocal-next-server-preset.b64", isDirectory: false)
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
    defer { try? files.removeItem(at: url) }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maxPresetBytes + 1), data.count <= maxPresetBytes,
          let encoded = String(data: data, encoding: .utf8), !encoded.isEmpty else { return nil }
    return ["server_presets_b64": encoded]
  }

  override func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    if let restored = launchOptions?[.bluetoothCentrals] as? [String], restored.contains(NextCV1.restorationID) {
      NextCV1.shared.resumeSavedLink()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    if let registrar = registry.registrar(forPlugin: "OmiLocalNextEnvironment") {
      let channel = FlutterMethodChannel(name: "org.omilocal.next/environment", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, reply in
        if call.method == "prepareOfflineRecordings" {
          do {
            let files = FileManager.default
            let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            var folder = support.appendingPathComponent("NextOfflineRecordings", isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            reply(folder.path)
          } catch {
            reply(FlutterError(code: "offline_storage_unavailable", message: nil, details: nil))
          }
          return
        }
        guard call.method == "takeLocalMacSettings" else {
          reply(FlutterMethodNotImplemented)
          return
        }
        let usb = Self.takeUSBPreset()
        let settings = self?.launchSettings ?? usb
        self?.launchSettings = nil
        reply(settings)
      }
    }
    let plugins: [(String, FlutterPlugin.Type)] = [
      ("OmiLocalNextCV1", NextCV1.self),
      ("AudioSessionPlugin", AudioSessionPlugin.self),
      ("FPPDeviceInfoPlusPlugin", FPPDeviceInfoPlusPlugin.self),
      ("FlutterSecureStoragePlugin", FlutterSecureStoragePlugin.self),
      ("FlutterSound", FlutterSound.self),
      ("PermissionHandlerPlugin", PermissionHandlerPlugin.self),
      ("JustAudioPlugin", JustAudioPlugin.self),
      ("PathProviderPlugin", PathProviderPlugin.self),
      ("QuickActionsPlugin", QuickActionsPlugin.self),
      ("FPPSharePlusPlugin", FPPSharePlusPlugin.self),
      ("SharedPreferencesPlugin", SharedPreferencesPlugin.self)
    ]
    for (name, plugin) in plugins {
      if let registrar = registry.registrar(forPlugin: name) {
        plugin.register(with: registrar)
      }
    }
  }
}

class NextSceneDelegate: FlutterSceneDelegate {}
