import Foundation

// CoreBluetooth and Flutter callbacks are serialized on the main queue. An earlier
// enable acknowledgement cannot restore a muted or replaced subscription.
struct CV1AudioSubscription {
  private var desired: Int?
  private var confirmed: Int?
  private var last: Int?

  mutating func request(_ enabled: Bool, token: Int) -> String? {
    guard token > 0 else { return "invalid_arguments" }
    if enabled {
      if let desired, desired != token { return "busy" }
      if desired == nil, token == last { return "stale" }
      desired = token
      last = token
    } else {
      guard desired == token || (desired == nil && last == token) else { return "stale" }
      desired = nil
    }
    return nil
  }

  mutating func acknowledge(_ enabled: Bool, token: Int) {
    confirmed = enabled ? token : nil
  }

  var emitting: Int? { desired == confirmed ? confirmed : nil }
}

// Restoration may precede powered-on and Flutter registration.
struct CV1Restoration<Peer> {
  private var pending: Peer?
  var isPending: Bool { pending != nil }

  mutating func remember(_ peers: [Peer], selected: UUID, id: (Peer) -> UUID) {
    pending = peers.first { id($0) == selected }
  }

  mutating func take() -> Peer? {
    defer { pending = nil }
    return pending
  }
}

enum CV1Wire {
  static func buttonCode(_ data: Data) -> Int? {
    guard data.count >= 4 else { return nil }
    return data.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
  }
}

// READ on a legacy ring releases records in firmware. Accept only a bounded
// window at the oldest unread sequence. DATA can split a record at any byte.
final class CV1LegacyRead {
  private static let recordSize = 444
  let start: UInt64
  let count: Int
  private var began = false
  private var received = Data()

  init?(info: Data) {
    guard info.count == 31, info.first == 2,
          Self.integer(info, 29..<31) == UInt64(Self.recordSize) else { return nil }
    let oldest = Self.integer(info, 1..<9)
    let end = Self.integer(info, 9..<17)
    guard end <= UInt64(Int64.max), end > oldest, end - oldest <= Self.integer(info, 17..<21) else { return nil }
    start = oldest
    count = Int(min(32, end - oldest))
  }

  private static func integer(_ data: Data, _ field: Range<Int>) -> UInt64 {
    data.dropFirst(field.lowerBound).prefix(field.count).reduce(0) { ($0 << 8) | UInt64($1) }
  }

  var command: Data {
    var bytes = Data([0x11])
    withUnsafeBytes(of: start.bigEndian) { bytes.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(count).bigEndian) { bytes.append(contentsOf: $0) }
    return bytes
  }

  var wholeRecords: Data { received.prefix(received.count / Self.recordSize * Self.recordSize) }

  enum Step { case more, complete, interrupted }

  func receive(_ frame: Data) -> Step {
    switch frame.first {
    case 5:
      guard !began, frame.count == 13, Self.integer(frame, 1..<9) == start,
            Self.integer(frame, 9..<13) == UInt64(count) else { return .interrupted }
      began = true
    case 3:
      guard began, frame.count > 1, frame.count - 1 <= count * Self.recordSize - received.count else {
        return .interrupted
      }
      received.append(contentsOf: frame.dropFirst())
    case 4:
      guard began, frame.count == 10, frame.dropFirst().first == 0, Self.integer(frame, 2..<10) == start + UInt64(count),
            received.count == count * Self.recordSize else { return .interrupted }
      return .complete
    case 2:
      // A previously requested INFO reply can follow its ATT write acknowledgement.
      break
    case 1:
      guard frame.count == 2, frame.dropFirst().first == 0 else { return .interrupted }
    default: return .interrupted
    }
    return .more
  }
}
