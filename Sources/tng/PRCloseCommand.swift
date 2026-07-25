import ArgumentParser

struct PRCloseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a Tangled pull request"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Flag(help: "Output the created status record as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).setStatus(
        pullRequestURI: pullRequestURI,
        status: .closed,
        json: json
      )
    }
  }
}
