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
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    let plugins: [(String, FlutterPlugin.Type)] = [
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
