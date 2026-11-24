import Flutter
import UIKit
import audio_session
import flutter_secure_storage
import flutter_sound
import just_audio
import path_provider_foundation
import permission_handler_apple
import shared_preferences_foundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var launchSettings: [String: String]? = {
    let field = "OMI_LOCAL_SERVER_PRESETS_B64"
    let maxEncodedBytes = 4 * ((32_768 + 2) / 3)
    defer {
      unsetenv(field)
      unsetenv("OMI_LOCAL_MAC_URL")
      unsetenv("OMI_LOCAL_MAC_KEY")
    }
    guard let raw = getenv(field), strnlen(raw, maxEncodedBytes + 1) <= maxEncodedBytes,
          let encoded = String(validatingCString: raw), !encoded.isEmpty else { return nil }
    return ["server_presets_b64": encoded]
  }()

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    if let registrar = registry.registrar(forPlugin: "OmiLocalNextEnvironment") {
      let channel = FlutterMethodChannel(name: "org.omilocal.next/environment", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, reply in
        guard call.method == "takeLocalMacSettings" else {
          reply(FlutterMethodNotImplemented)
          return
        }
        let settings = self?.launchSettings
        self?.launchSettings = nil
        reply(settings)
      }
    }
    let plugins: [(String, FlutterPlugin.Type)] = [
      ("OmiLocalNextCV1", NextCV1.self),
      ("AudioSessionPlugin", AudioSessionPlugin.self),
      ("FlutterSecureStoragePlugin", FlutterSecureStoragePlugin.self),
      ("FlutterSound", FlutterSound.self),
      ("PermissionHandlerPlugin", PermissionHandlerPlugin.self),
      ("JustAudioPlugin", JustAudioPlugin.self),
      ("PathProviderPlugin", PathProviderPlugin.self),
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
