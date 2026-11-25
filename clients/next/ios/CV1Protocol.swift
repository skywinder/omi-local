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
