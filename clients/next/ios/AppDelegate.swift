import Flutter
import UIKit
import UserNotifications
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
  private let reminders = NextTaskReminders()

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
    if let registrar = registry.registrar(forPlugin: "OmiLocalNextTaskReminders") {
      reminders.attach(registrar.messenger())
    }
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

private final class NextTaskReminders: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let prefix = "omi.next.task."

  func attach(_ messenger: FlutterBinaryMessenger) {
    center.delegate = self
    let channel = FlutterMethodChannel(name: "org.omilocal.next/reminders", binaryMessenger: messenger)
    channel.setMethodCallHandler { [self] call, reply in
      switch call.method {
      case "timezone": reply(TimeZone.current.identifier)
      case "status": status(reply)
      case "request":
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in self.status(reply) }
      case "replace": replace(call.arguments, reply: reply)
      case "clear":
        center.getDeliveredNotifications { delivered in
          let ids = delivered.map { $0.request.identifier }.filter { $0.hasPrefix(self.prefix) }
          self.center.removeDeliveredNotifications(withIdentifiers: ids)
          self.replace([[String: Any]]()) { result in
            reply(result is FlutterError ? result : nil)
          }
        }
      default: reply(FlutterMethodNotImplemented)
      }
    }
  }

  private func authorization(_ result: @escaping (Bool) -> Void) {
    center.getNotificationSettings { settings in
      result([.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus))
    }
  }

  private func status(_ reply: @escaping FlutterResult) {
    authorization { allowed in
      DispatchQueue.main.async { reply(["allowed": allowed, "precise": true]) }
    }
  }

  private func replace(_ arguments: Any?, reply: @escaping FlutterResult) {
    guard let rows = arguments as? [[String: Any]], rows.count <= 96 else {
      reply(FlutterError(code: "local_task_reminders_invalid", message: nil, details: nil))
      return
    }
    var requests = [UNNotificationRequest]()
    var ids = Set<String>()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for row in rows {
      guard let id = row["id"] as? String,
            id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
            ids.insert(prefix + id).inserted,
            let time = row["at"] as? NSNumber, time.doubleValue.isFinite,
            let title = row["title"] as? String, !title.isEmpty, title.utf16.count <= 128,
            let body = row["body"] as? String, !body.isEmpty, body.utf16.count <= 400 else {
        reply(FlutterError(code: "local_task_reminders_invalid", message: nil, details: nil))
        return
      }
      let date = Date(timeIntervalSince1970: time.doubleValue / 1000)
      guard date > Date() else { continue }
      var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
      components.timeZone = calendar.timeZone
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      requests.append(UNNotificationRequest(identifier: prefix + id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
    let desired = Array(requests.prefix(48))
    authorization { allowed in
      let active = allowed ? desired : []
      let keep = Set(active.map(\.identifier))
      self.center.getPendingNotificationRequests { current in
        let remove = current.map(\.identifier).filter { $0.hasPrefix(self.prefix) && !keep.contains($0) }
        self.center.removePendingNotificationRequests(withIdentifiers: remove)
        self.center.removeDeliveredNotifications(withIdentifiers: remove)
        let pending = DispatchGroup()
        let errors = NextReminderErrors()
        let previous = Dictionary(uniqueKeysWithValues: current.map { ($0.identifier, $0) })
        for request in active {
          if let old = previous[request.identifier],
             old.content.title == request.content.title, old.content.body == request.content.body,
             (old.trigger as? UNCalendarNotificationTrigger)?.dateComponents ==
               (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents {
            continue
          }
          pending.enter()
          self.center.add(request) { error in
            if error != nil {
              errors.mark()
            }
            pending.leave()
          }
        }
        pending.notify(queue: .main) {
          if errors.failed {
            reply(FlutterError(code: "local_task_reminders_unavailable", message: nil, details: nil))
          } else {
            reply(["allowed": allowed, "precise": true])
          }
        }
      }
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
    completion([.banner, .sound])
  }
}

private final class NextReminderErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func mark() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var failed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
