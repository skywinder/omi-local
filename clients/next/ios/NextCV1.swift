import CoreBluetooth
import Flutter
import Foundation

// The materializer appends CV1UUID from the pinned Omi Dart protocol constants.
final class NextCV1: NSObject, FlutterPlugin, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private enum Intent {
    case idle, scan, link(UUID)
  }

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

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = NextCV1()
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

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    publish(phase)
    if case .idle = intent, let id = saved, CBManager.authorization == .allowedAlways {
      start(.link(id), phase: "reconnecting")
    }
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
    case "disconnect":
      UserDefaults.standard.removeObject(forKey: savedKey)
      close()
      result(nil)
    case "close":
      close()
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func publish(_ value: String) {
    phase = value
    var state: [String: Any] = ["type": "state", "phase": phase, "generation": generation]
    if phase == "ready", let codec { state["codec"] = codec }
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
    peer = nil
    central = nil
    codec = nil
    codecChar = nil
    audioChar = nil
    buttonChar = nil
    buttonConfirmed = false
    changingAudio = false
    subscription = CV1AudioSubscription()
    let pending = audioQueue
    audioQueue.removeAll()
    for item in pending { item.reply(problem("stale")) }
  }

  private func close() {
    clearLink()
    intent = .idle
    retryDelay = 1
    seen.removeAll()
    publish("idle")
  }

  private func start(_ desired: Intent, phase: String) {
    clearLink()
    intent = desired
    publish(phase)
    central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    if case .scan = desired {
      after(12) { bridge in
        if bridge.central?.isScanning == true { bridge.central?.stopScan() }
        bridge.intent = .idle
        bridge.publish("idle")
      }
    }
  }

  private func lost(_ reconnect: Bool) {
    guard case let .link(id) = intent else { return }
    clearLink()
    guard reconnect, saved == id else {
      intent = .idle
      publish("failed")
      return
    }
    publish("reconnecting")
    let delay = retryDelay
    retryDelay = min(30, 2 * delay)
    after(delay) { $0.start(.link(id), phase: "reconnecting") }
  }

  func centralManagerDidUpdateState(_ manager: CBCentralManager) {
    guard central === manager else { return }
    guard manager.state == .poweredOn else {
      if manager.state == .unknown { return }
      // A powered-off radio cannot serve the existing GATT characteristics.
      // Keep one manager to observe the next powered-on event, without polling.
      let desired = intent
      clearLink()
      central = manager
      manager.delegate = self
      if case let .link(id) = desired, saved == id { intent = desired } else { intent = .idle }
      publish("unavailable")
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
      if peer != nil { return }
      if phase == "unavailable" {
        start(.link(id), phase: "reconnecting")
        return
      }
      if let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
        attach(known, manager)
      } else {
        manager.scanForPeripherals(withServices: [CV1UUID.audioService])
        after(15) { $0.lost(true) }
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
    if saved != device.identifier { after(20) { $0.lost(false) } }
  }

  func centralManager(_ manager: CBCentralManager, didConnect device: CBPeripheral) {
    guard central === manager, peer === device else { return }
    after(15) { $0.lost(true) }
    device.discoverServices([CV1UUID.audioService, CV1UUID.buttonService])
  }

  func centralManager(_ manager: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
    if central === manager, peer === device { lost(true) }
  }

  func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
    if central === manager, peer === device { lost(true) }
  }

  func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
    guard peer === device else { return }
    guard error == nil, let services = device.services,
          let audio = services.first(where: { $0.uuid == CV1UUID.audioService }),
          let button = services.first(where: { $0.uuid == CV1UUID.buttonService }) else { return lost(false) }
    device.discoverCharacteristics([CV1UUID.audio, CV1UUID.codec], for: audio)
    device.discoverCharacteristics([CV1UUID.button], for: button)
  }

  func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peer === device else { return }
    guard error == nil, let chars = service.characteristics else { return lost(true) }
    if service.uuid == CV1UUID.audioService {
      guard let stream = chars.first(where: { $0.uuid == CV1UUID.audio && $0.properties.contains(.notify) }),
            let format = chars.first(where: { $0.uuid == CV1UUID.codec && $0.properties.contains(.read) }) else {
        return lost(false)
      }
      audioChar = stream
      codecChar = format
      device.readValue(for: format)
    } else if service.uuid == CV1UUID.buttonService {
      guard let button = chars.first(where: { $0.uuid == CV1UUID.button && $0.properties.contains(.notify) }) else {
        return lost(false)
      }
      buttonChar = button
      device.setNotifyValue(true, for: button)
    }
  }

  private func readyIfConfigured() {
    guard phase != "ready", let peer, codec != nil, audioChar != nil, buttonConfirmed else { return }
    cancelTimer()
    retryDelay = 1
    UserDefaults.standard.set(peer.identifier.uuidString, forKey: savedKey)
    publish("ready")
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
    if char === buttonChar {
      guard error == nil, char.isNotifying else { return lost(true) }
      buttonConfirmed = true
      readyIfConfigured()
    } else if char === audioChar, changingAudio {
      cancelTimer()
      guard error == nil, char.isNotifying == audioQueue.first?.enabled else { return lost(true) }
      changingAudio = false
      changeAudio()
    }
  }

  func peripheral(_ device: CBPeripheral, didUpdateValueFor char: CBCharacteristic, error: Error?) {
    guard peer === device else { return }
    guard error == nil, let data = char.value else { return lost(true) }
    if char === codecChar {
      guard let id = data.first, id == 20 || id == 21 else { return lost(false) }
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
