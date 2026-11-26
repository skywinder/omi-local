import CoreBluetooth
import Flutter
import Foundation

// The materializer appends CV1UUID from the pinned Omi Dart protocol constants.
final class NextCV1: NSObject, FlutterPlugin, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private enum Intent {
    case idle, scan, link(UUID)
  }

  static let restorationID = "org.omilocal.next.cv1.central"
  static let shared = NextCV1()
  private var restoration = CV1Restoration<CBPeripheral>()
  private var resettingRestoredAudio = false
  private let savedKey = "org.omilocal.next.cv1.selected"
  private var sink: FlutterEventSink?
  private var central: CBCentralManager?
  private var peer: CBPeripheral?
  private var intent = Intent.idle
  private var phase = "idle"
  private var generation = 0
  private var seen: Set<UUID> = []
  private var timer: DispatchWorkItem?
  private var retryDelay: TimeInterval = 1
  private var codec: Int?
  private var codecChar: CBCharacteristic?
  private var audioChar: CBCharacteristic?
  private var buttonChar: CBCharacteristic?
  private var buttonConfirmed = false
  private var subscription = CV1AudioSubscription()
  private var audioQueue: [(enabled: Bool, token: Int, reply: FlutterResult)] = []
  private var changingAudio = false
  private var metrics: [String: Any] = [:]
  private var metricChars: [String: CBCharacteristic] = [:]
  private var pendingReads: Set<String> = []
  private var readingRSSI = false
  private var clearReply: FlutterResult?
  private var clearSerial = 0
  private var storageCommand: CBCharacteristic?
  private var enablingStorageNotifications = false
  private var observingBattery = false
  private var features: Int?
  private var setting: (field: String, char: CBCharacteristic, value: Int, reply: FlutterResult)?

  private let metricServices: [CBUUID: [String: CBUUID]] = [
    CV1UUID.batteryService: ["battery": CV1UUID.battery],
    CV1UUID.storageService: ["storageStatus": CV1UUID.storageStatus],
    CV1UUID.deviceInfo: ["firmware": CV1UUID.firmware, "hardware": CV1UUID.hardware,
                         "model": CV1UUID.model, "manufacturer": CV1UUID.manufacturer],
    CV1UUID.settings: ["led": CV1UUID.led, "gain": CV1UUID.gain, "charging": CV1UUID.charging],
    CV1UUID.featuresService: ["features": CV1UUID.features],
  ]

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = shared
    let messenger = registrar.messenger()
    let commands = FlutterMethodChannel(name: "org.omilocal.next/cv1", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(bridge, channel: commands)
    FlutterEventChannel(name: "org.omilocal.next/cv1.events", binaryMessenger: messenger).setStreamHandler(bridge)
  }

  private func problem(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private var saved: UUID? {
    UserDefaults.standard.string(forKey: savedKey).flatMap(UUID.init(uuidString:))
  }

  func resumeSavedLink() {
    if case .idle = intent, let id = saved, CBManager.authorization == .allowedAlways {
      start(.link(id), phase: "reconnecting")
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    publish(phase)
    resumeSavedLink()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    close()
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "scan":
      if case .link = intent, phase == "ready" || phase == "connecting" {
        return result(problem("busy"))
      }
      seen.removeAll()
      start(.scan, phase: "scanning")
      result(nil)
    case "connect":
      guard let raw = args?["id"] as? String, let id = UUID(uuidString: raw), seen.contains(id) || saved == id else {
        return result(problem("unknown_device"))
      }
      start(.link(id), phase: "connecting")
      result(nil)
    case "setAudio":
      guard let requested = args?["generation"] as? Int, let token = args?["subscription"] as? Int,
            let enabled = args?["enabled"] as? Bool else {
        return result(problem("invalid_arguments"))
      }
      guard requested == generation else { return result(problem("stale")) }
      guard phase == "ready", audioChar != nil else { return result(problem("not_ready")) }
      if let error = subscription.request(enabled, token: token) { return result(problem(error)) }
      audioQueue.append((enabled, token, result))
      changeAudio()
    case "sampleDiagnostics":
      sample()
      result(nil)
    case "sampleSignal":
      sampleSignal()
      result(nil)
    case "clearStorage":
      guard phase == "ready", let peer, let char = storageCommand, char.isNotifying, clearReply == nil,
            args?["generation"] as? Int == generation, args?["deviceId"] as? String == peer.identifier.uuidString,
            let info = metrics["storageInfo"] as? FlutterStandardTypedData, info.data.count >= 31,
            info.data[29] == 1, info.data[30] == 188, !changingAudio, audioQueue.isEmpty,
            audioChar?.isNotifying != true else { return result(problem("storage_busy")) }
      clearSerial += 1
      let serial = clearSerial
      clearReply = result
      peer.writeValue(Data([0x13]), for: char, type: .withResponse)
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
        if self?.clearSerial == serial { self?.finishClear(false) }
      }
    case "writeSetting":
      guard phase == "ready", let peer, let field = args?["field"] as? String,
            field == "led" || field == "gain", let char = metricChars[field],
            supportsSetting(field), char.properties.contains(.write), let value = args?["value"] as? Int,
            (0...(field == "gain" ? 8 : 100)).contains(value), args?["generation"] as? Int == generation,
            setting == nil, !changingAudio, audioQueue.isEmpty, audioChar?.isNotifying != true else {
        return result(problem("setting_unavailable"))
      }
      setting = (field, char, value, result)
      peer.writeValue(Data([UInt8(value)]), for: char, type: .withResponse)
    case "disconnect":
      UserDefaults.standard.removeObject(forKey: savedKey)
      close(reason: "manual")
      result(nil)
    case "close":
      close()
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func publish(_ value: String, reason: String? = nil, code: Int? = nil) {
    phase = value
    var state: [String: Any] = ["type": "state", "phase": phase, "generation": generation]
    if phase == "ready", let codec { state["codec"] = codec }
    if phase == "ready" || phase == "reconnecting", case let .link(id) = intent {
      state["deviceId"] = id.uuidString
    }
    state["reason"] = reason
    state["code"] = code
    sink?(state)
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
  }

  private func after(_ seconds: TimeInterval, _ action: @escaping (NextCV1) -> Void) {
    cancelTimer()
    let token = generation
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      action(self)
    }
    timer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func clearLink() {
    generation += 1
    cancelTimer()
    central?.delegate = nil
    peer?.delegate = nil
    if let central, central.state == .poweredOn {
      if central.isScanning { central.stopScan() }
      if let peer { central.cancelPeripheralConnection(peer) }
    }
    _ = restoration.take()
    resettingRestoredAudio = false
    peer = nil
    central = nil
    codec = nil
    codecChar = nil
    audioChar = nil
    buttonChar = nil
    buttonConfirmed = false
    changingAudio = false
    subscription = CV1AudioSubscription()
    finishClear(false)
    storageCommand = nil
    enablingStorageNotifications = false
    metricChars.removeAll()
    metrics.removeAll()
    pendingReads.removeAll()
    readingRSSI = false
    observingBattery = false
    features = nil
    let previousSetting = setting
    setting = nil
    previousSetting?.reply(problem("stale"))
    let pending = audioQueue
    audioQueue.removeAll()
    for item in pending { item.reply(problem("stale")) }
  }

  private func close(reason: String? = nil) {
    clearLink()
    intent = .idle
    retryDelay = 1
    seen.removeAll()
    publish("idle", reason: reason)
  }

  private func start(_ desired: Intent, phase: String) {
    clearLink()
    intent = desired
    publish(phase)
    var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
    if case .link = desired { options[CBCentralManagerOptionRestoreIdentifierKey] = Self.restorationID }
    central = CBCentralManager(delegate: self, queue: .main, options: options)
    if case .scan = desired {
      after(12) { bridge in
        if bridge.central?.isScanning == true { bridge.central?.stopScan() }
        bridge.intent = .idle
        bridge.publish("idle")
      }
    }
  }

  private func lost(_ reconnect: Bool, reason: String = "dropped", code: Int? = nil) {
    guard case let .link(id) = intent else { return }
    clearLink()
    guard reconnect, saved == id else {
      intent = .idle
      publish("failed", reason: reason, code: code)
      return
    }
    publish("reconnecting", reason: reason, code: code)
    let delay = retryDelay
    retryDelay = min(30, 2 * delay)
    after(delay) { $0.start(.link(id), phase: "reconnecting") }
  }

  func centralManager(_ manager: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard central === manager, case let .link(wanted) = intent, saved == wanted,
          let peers = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
    restoration.remember(peers, selected: wanted) { $0.identifier }
    if manager.state == .poweredOn { centralManagerDidUpdateState(manager) }
  }

  func centralManagerDidUpdateState(_ manager: CBCentralManager) {
    guard central === manager else { return }
    guard manager.state == .poweredOn else {
      if manager.state == .unknown || (manager.state == .resetting && restoration.isPending) { return }
      // A powered-off radio cannot serve the existing GATT characteristics.
      // Keep one manager to observe the next powered-on event, without polling.
      let desired = intent
      clearLink()
      central = manager
      manager.delegate = self
      if case let .link(id) = desired, saved == id { intent = desired } else { intent = .idle }
      publish("unavailable", reason: manager.state == .unauthorized ? "permission" : "radio")
      return
    }
    switch intent {
    case .idle: publish("idle")
    case .scan:
      manager.scanForPeripherals(withServices: [CV1UUID.audioService])
      for candidate in manager.retrieveConnectedPeripherals(withServices: [CV1UUID.audioService]) {
        offer(candidate, name: nil)
      }
    case let .link(id):
      if let device = restoration.take() {
        peer = device
        device.delegate = self
        switch device.state {
        case .connected: centralManager(manager, didConnect: device)
        case .connecting: break // iOS already owns the pending connection.
        default: attach(device, manager)
        }
        return
      }
      if peer != nil { return }
      if phase == "unavailable" {
        start(.link(id), phase: "reconnecting")
        return
      }
      if let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
        attach(known, manager)
      } else {
        manager.scanForPeripherals(withServices: [CV1UUID.audioService])
        after(15) { $0.lost(true, reason: "timeout") }
      }
    }
  }

  private func offer(_ device: CBPeripheral, name: String?) {
    guard seen.insert(device.identifier).inserted else { return }
    sink?(["type": "device", "id": device.identifier.uuidString, "name": name ?? device.name ?? "Omi CV1"])
  }

  func centralManager(_ manager: CBCentralManager, didDiscover device: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard central === manager else { return }
    switch intent {
    case .scan: offer(device, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    case let .link(id) where id == device.identifier && peer == nil: attach(device, manager)
    default: break
    }
  }

  private func attach(_ device: CBPeripheral, _ manager: CBCentralManager) {
    if manager.isScanning { manager.stopScan() }
    cancelTimer()
    peer = device
    device.delegate = self
    manager.connect(device)
    // For the remembered peer CoreBluetooth can wait for its return without scans.
    if saved != device.identifier { after(20) { $0.lost(false, reason: "timeout") } }
  }

  func centralManager(_ manager: CBCentralManager, didConnect device: CBPeripheral) {
    guard central === manager, peer === device else { return }
    after(15) { $0.lost(true, reason: "timeout") }
    device.discoverServices([CV1UUID.audioService, CV1UUID.buttonService] + Array(metricServices.keys))
  }

  func centralManager(_ manager: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
    if central === manager, peer === device { lost(true, reason: "connect", code: bluetoothCode(error)) }
  }

  func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
    guard central === manager, peer === device else { return }
    let code = bluetoothCode(error)
    let reason: String
    switch code {
    case CBError.Code.connectionTimeout.rawValue: reason = "timeout"
    case CBError.Code.peripheralDisconnected.rawValue: reason = "remote"
    default: reason = "dropped"
    }
    lost(true, reason: reason, code: code)
  }

  private func bluetoothCode(_ error: Error?) -> Int? {
    guard let error = error as NSError?, error.domain == CBErrorDomain else { return nil }
    return error.code
  }

  func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
    guard peer === device else { return }
    guard error == nil, let services = device.services,
          let audio = services.first(where: { $0.uuid == CV1UUID.audioService }),
          let button = services.first(where: { $0.uuid == CV1UUID.buttonService }) else { return lost(false, reason: "incompatible") }
    device.discoverCharacteristics([CV1UUID.audio, CV1UUID.codec], for: audio)
    device.discoverCharacteristics([CV1UUID.button], for: button)
    for service in services {
      if let fields = metricServices[service.uuid] {
        let extra = service.uuid == CV1UUID.storageService ? [CV1UUID.storageCommand] : []
        device.discoverCharacteristics(Array(fields.values) + extra, for: service)
      }
    }
  }

  func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peer === device else { return }
    if let fields = metricServices[service.uuid] {
      guard error == nil, let chars = service.characteristics else { return }
      if service.uuid == CV1UUID.storageService {
        storageCommand = chars.first { $0.uuid == CV1UUID.storageCommand && $0.properties.contains([.notify, .write]) }
      }
      for (key, id) in fields {
        if let char = chars.first(where: { $0.uuid == id && $0.properties.contains(.read) }) {
          metricChars[key] = char
        }
      }
      if phase == "ready" {
        observeBattery()
        sample()
      }
      return
    }
    guard error == nil, let chars = service.characteristics else { return lost(true) }
    if service.uuid == CV1UUID.audioService {
      guard let stream = chars.first(where: { $0.uuid == CV1UUID.audio && $0.properties.contains(.notify) }),
            let format = chars.first(where: { $0.uuid == CV1UUID.codec && $0.properties.contains(.read) }) else {
        return lost(false, reason: "incompatible")
      }
      audioChar = stream
      // Restored notification state belongs to the old process; only a fresh
      // Dart subscription may start publishing audio in this process.
      if stream.isNotifying && subscription.emitting == nil {
        resettingRestoredAudio = true
        device.setNotifyValue(false, for: stream)
      }
      codecChar = format
      device.readValue(for: format)
    } else if service.uuid == CV1UUID.buttonService {
      guard let button = chars.first(where: { $0.uuid == CV1UUID.button && $0.properties.contains(.notify) }) else {
        return lost(false, reason: "incompatible")
      }
      buttonChar = button
      if button.isNotifying {
        buttonConfirmed = true
        readyIfConfigured()
      } else {
        device.setNotifyValue(true, for: button)
      }
    }
  }

  private func readyIfConfigured() {
    guard phase != "ready", let peer, codec != nil, audioChar != nil, buttonConfirmed, !resettingRestoredAudio else { return }
    cancelTimer()
    retryDelay = 1
    UserDefaults.standard.set(peer.identifier.uuidString, forKey: savedKey)
    if let name = peer.name { metrics["name"] = String(name.prefix(80)) }
    publish("ready")
    publishMetrics()
    observeBattery()
  }

  private func changeAudio() {
    guard !changingAudio, let peer, let audioChar else { return }
    while let next = audioQueue.first {
      if next.enabled != audioChar.isNotifying {
        changingAudio = true
        after(10) { $0.lost(true) }
        peer.setNotifyValue(next.enabled, for: audioChar)
        return
      }
      subscription.acknowledge(next.enabled, token: next.token)
      audioQueue.removeFirst().reply(nil)
    }
  }

  func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor char: CBCharacteristic, error: Error?) {
    guard peer === device else { return }
    if char === storageCommand {
      enablingStorageNotifications = false
      if error == nil, char.isNotifying { sampleStorageInfo() }
    } else if char === buttonChar {
      guard error == nil, char.isNotifying else { return lost(true) }
      buttonConfirmed = true
      readyIfConfigured()
    } else if char === audioChar, resettingRestoredAudio {
      resettingRestoredAudio = false
      guard error == nil, !char.isNotifying else { return lost(true) }
      readyIfConfigured()
    } else if char === audioChar, changingAudio {
      cancelTimer()
      guard error == nil, char.isNotifying == audioQueue.first?.enabled else { return lost(true) }
      changingAudio = false
      changeAudio()
    }
  }

  private func publishMetrics(_ measurement: String? = nil) {
    guard phase == "ready" else { return }
    var event: [String: Any] = ["type": "diagnostics", "generation": generation, "values": metrics]
    event["measurement"] = measurement
    sink?(event)
  }

  private func observeBattery() {
    guard !observingBattery, let peer, let char = metricChars["battery"] else { return }
    observingBattery = true
    if char.properties.contains(.notify), !char.isNotifying { peer.setNotifyValue(true, for: char) }
    if char.properties.contains(.read), pendingReads.insert("battery").inserted { peer.readValue(for: char) }
  }

  private func supportsSetting(_ field: String) -> Bool {
    if field == "led" { return (features ?? 0) & CV1UUID.ledMask != 0 }
    if field == "gain" { return (features ?? 0) & CV1UUID.gainMask != 0 }
    return false
  }

  private func sample() {
    guard phase == "ready", let peer, !changingAudio, audioQueue.isEmpty, audioChar?.isNotifying != true else { return }
    for (field, char) in metricChars {
      if field == "features", features != nil { continue }
      if (field == "led" || field == "gain"), !supportsSetting(field) { continue }
      if field == "charging", (features ?? 0) == 0 { continue }
      if ["firmware", "hardware", "model", "manufacturer"].contains(field), metrics[field] != nil { continue }
      if pendingReads.insert(field).inserted { peer.readValue(for: char) }
    }
  }

  private func finishClear(_ acknowledged: Bool) {
    let reply = clearReply
    clearReply = nil
    reply?(acknowledged)
  }

  // Query ring metadata only while the audio stream is idle.
  private func sampleStorageInfo() {
    guard phase == "ready", let peer, let char = storageCommand, clearReply == nil, !changingAudio, audioQueue.isEmpty,
          audioChar?.isNotifying != true, !enablingStorageNotifications else { return }
    if char.isNotifying {
      peer.writeValue(Data([0x10]), for: char, type: .withResponse)
    } else {
      enablingStorageNotifications = true
      peer.setNotifyValue(true, for: char)
    }
  }

  private func sampleSignal() {
    guard phase == "ready", let peer, !readingRSSI else { return }
    readingRSSI = true
    peer.readRSSI()
  }

  func peripheral(_ device: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    guard peer === device else { return }
    readingRSSI = false
    metrics["rssi"] = error == nil && (-127 ... -1).contains(RSSI.intValue) ? RSSI.intValue : nil
    publishMetrics("rssi")
  }

  func peripheral(_ device: CBPeripheral, didWriteValueFor char: CBCharacteristic, error: Error?) {
    guard peer === device else { return }
    if char === storageCommand {
      if error != nil { finishClear(false) }
      return
    }
    guard let write = setting, write.char === char else { return }
    setting = nil
    if error == nil {
      metrics[write.field] = write.value
      publishMetrics()
      write.reply(nil)
    } else {
      write.reply(problem("setting_write"))
    }
  }

  private func readMetric(_ field: String, data: Data?) {
    pendingReads.remove(field)
    switch field {
    case "features":
      features = data.flatMap { bytes in
        bytes.count >= 4 ? Int(bytes[0]) | (Int(bytes[1]) << 8) : nil
      } ?? 0
      sample()
    case "battery":
      guard let level = data?.first, level <= 100 else { return }
      metrics[field] = Int(level)
    case "storageStatus":
      metrics.removeValue(forKey: "storageInfo")
      metrics[field] = data.flatMap { $0.count == 16 ? FlutterStandardTypedData(bytes: $0) : nil }
      if metrics[field] != nil { sampleStorageInfo() }
    case "led", "gain":
      if supportsSetting(field), metricChars[field]?.properties.contains(.write) == true {
        metrics[field + "Writable"] = true
      }
      metrics[field] = data?.first.flatMap { $0 <= 100 ? Int($0) : nil }
    case "charging":
      metrics[field] = data?.first.map { $0 == 1 }
    default:
      metrics[field] = data.flatMap {
        $0.count <= 64 ? String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) : nil
      }
    }
    publishMetrics(field == "battery" ? field : nil)
  }

  func peripheral(_ device: CBPeripheral, didUpdateValueFor char: CBCharacteristic, error: Error?) {
    guard peer === device else { return }
    if char === storageCommand {
      if error == nil, let data = char.value, data.count == 2, data.first == 1, clearReply != nil {
        finishClear(data[1] == 0)
        return
      }
      if phase == "ready", error == nil, let data = char.value, data.first == 0x02, data.count == 31 || data.count == 41 {
        metrics["storageInfo"] = FlutterStandardTypedData(bytes: data)
        publishMetrics()
      }
      return
    }
    if let field = metricChars.first(where: { $0.value === char })?.key {
      readMetric(field, data: error == nil ? char.value : nil)
      return
    }
    guard error == nil, let data = char.value else { return lost(true) }
    if char === codecChar {
      guard let id = data.first, id == 20 || id == 21 else { return lost(false, reason: "incompatible") }
      codec = Int(id)
      readyIfConfigured()
    } else if phase == "ready", char === audioChar, let token = subscription.emitting, !data.isEmpty {
      sink?(["type": "audio", "generation": generation, "subscription": token, "bytes": FlutterStandardTypedData(bytes: data)])
    } else if phase == "ready", char === buttonChar, let code = CV1Wire.buttonCode(data) {
      sink?(["type": "button", "generation": generation, "code": code])
    }
  }

  func peripheral(_ device: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    if peer === device, invalidatedServices.contains(where: { [CV1UUID.audioService, CV1UUID.buttonService].contains($0.uuid) }) {
      lost(true)
    }
  }
}
