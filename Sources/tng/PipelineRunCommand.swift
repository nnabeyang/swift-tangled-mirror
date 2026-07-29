import ArgumentParser
import Foundation
import SwiftTangled

struct PipelineRunInput: ExpressibleByArgument, Equatable, Sendable {
  let key: String
  let value: String

  init(key: String, value: String) {
    self.key = key
    self.value = value
  }

  init?(argument: String) {
    guard let separator = argument.firstIndex(of: "=") else {
      return nil
    }
    let key = argument[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      return nil
    }
    self.init(
      key: key,
      value: String(argument[argument.index(after: separator)...])
    )
  }
}

struct PipelineRunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a Tangled CI pipeline at an explicit commit"
  )

  @Argument(help: "Full 40-character commit SHA")
  var commit: String

  @Option(
    name: .customLong("repo"),
    help: "Repository reference used to locate its Spindle (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Spindle hostname or URL; overrides repository discovery")
  var spindle: String?

  @Option(help: "Git ref associated with the commit")
  var ref: String?

  @Option(
    parsing: .unconditionalSingleValue,
    help: "Run only the named workflow; repeat for multiple workflows"
  )
  var workflow: [String] = []

  @Option(
    parsing: .unconditionalSingleValue,
    help: "Manual input in key=value form; repeat for multiple inputs"
  )
  var input: [PipelineRunInput] = []

  @Flag(help: "Output the new pipeline AT URI as JSON")
  var json = false

  mutating func validate() throws {
    if let spindle, spindle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--spindle must not be empty")
    }
    if let ref, ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--ref must not be empty")
    }
    if workflow.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      throw ValidationError("--workflow must not be empty")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).run(
        commit: commit,
        repository: repository,
        spindle: spindle,
        ref: ref,
        workflows: workflow,
        inputs: input.map { PipelineManualInput(key: $0.key, value: $0.value) },
        json: json
      )
    }
  }
}
