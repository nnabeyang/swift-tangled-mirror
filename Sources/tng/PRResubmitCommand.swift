import ArgumentParser

struct PRResubmitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resubmit",
    abstract: "Add a round from an updated branch or patch file"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Option(help: "Read a cumulative git diff or git format-patch from this file")
  var patchFile: String?

  @Flag(help: "Output the updated pull request and round as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).resubmit(
        pullRequestURI: pullRequestURI,
        patchFile: patchFile,
        json: json
      )
    }
  }
}
