import ArgumentParser

struct EventsWatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Watch live Tangled events from Jetstream"
  )

  @Option(help: "Only include this collection; repeat for multiple collections")
  var collection: [String] = []

  @Option(help: "Only include records created by this DID; repeat for multiple DIDs")
  var did: [String] = []

  @Option(help: "Resume from this Jetstream microsecond cursor")
  var cursor: Int64?

  @Flag(help: "Output one compact JSON object per event")
  var json = false

  mutating func validate() throws {
    guard collection.count <= 100 else {
      throw ValidationError("--collection may be repeated at most 100 times")
    }
    guard collection.allSatisfy({ !$0.isEmpty }) else {
      throw ValidationError("--collection must not be empty")
    }
    guard did.count <= 10_000 else {
      throw ValidationError("--did may be repeated at most 10000 times")
    }
    guard did.allSatisfy({ $0.hasPrefix("did:") }) else {
      throw ValidationError("--did values must start with 'did:'")
    }
    if let cursor, cursor < 0 {
      throw ValidationError("--cursor must not be negative")
    }
  }

  func run() async throws {
    try await runCLIStreamingCommand(jsonErrors: json) {
      try await EventsCommandService(formatter: .live).watch(
        collections: collection,
        dids: did,
        cursor: cursor,
        json: json
      )
    }
  }
}
