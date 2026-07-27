import ArgumentParser

struct PRResubmitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resubmit",
    abstract: "Add a round from an updated pushed branch"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Flag(help: "Output the updated pull request and round as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).resubmit(
        pullRequestURI: pullRequestURI,
        json: json
      )
    }
  }
}
