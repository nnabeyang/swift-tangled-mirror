public struct BobbinCoverage: Codable, Equatable, Sendable {
  public let ready: Bool
  public let eventsProcessed: UInt64
  public let lastCursor: UInt64

  public init(ready: Bool, eventsProcessed: UInt64, lastCursor: UInt64) {
    self.ready = ready
    self.eventsProcessed = eventsProcessed
    self.lastCursor = lastCursor
  }
}
