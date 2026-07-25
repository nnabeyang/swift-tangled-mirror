import ArgumentParser

struct PRDiffCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diff",
    abstract: "Show a pull request round as a unified diff"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Option(help: "Round number to show, starting at 0 (defaults to the latest round)")
  var round: Int?

  mutating func validate() throws {
    if let round, round < 0 {
      throw ValidationError("--round must be greater than or equal to 0")
    }
  }

  func run() async throws {
    try await runCLICommand {
      try await PRCommandService(formatter: .live).diff(
        pullRequestURI: pullRequestURI,
        roundNumber: round
      )
    }
  }
}
