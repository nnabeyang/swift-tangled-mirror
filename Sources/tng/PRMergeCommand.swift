import ArgumentParser

struct PRMergeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "merge",
    abstract: "Check or merge a Tangled pull request"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Flag(help: "Check whether the pull request can be merged without merging it")
  var check = false

  @Flag(help: "Allow all open pull requests in the dependency stack to be merged")
  var stack = false

  @Flag(help: "Output the result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).merge(
        pullRequestURI: pullRequestURI,
        checkOnly: check,
        allowStack: stack,
        json: json
      )
    }
  }
}
