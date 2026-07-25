import ArgumentParser
import Foundation

struct PipelineWatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Watch a Tangled CI pipeline until it finishes"
  )

  @Argument(help: "Spindle-local pipeline TID")
  var pipelineID: String

  @Option(
    name: .customLong("repo"),
    help: "Repository reference used to locate its Spindle (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Spindle hostname or URL; skips repository discovery")
  var spindle: String?

  @Option(help: "Polling interval in seconds")
  var interval = 2.0

  @Flag(help: "Output one compact pipeline JSON object per state change")
  var json = false

  mutating func validate() throws {
    guard (0.25 ... 60).contains(interval) else {
      throw ValidationError("--interval must be between 0.25 and 60 seconds")
    }
    if let spindle, spindle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--spindle must not be empty")
    }
  }

  func run() async throws {
    try await runCLIStreamingCommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).watch(
        pipelineID: pipelineID,
        repository: repository,
        spindle: spindle,
        interval: interval,
        json: json
      )
    }
  }
}
