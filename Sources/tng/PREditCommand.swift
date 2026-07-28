import ArgumentParser

struct PREditCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit a Tangled pull request"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Option(name: [.customShort("t"), .long], help: "New pull request title")
  var title: String?

  @Option(
    name: [.customShort("b"), .long],
    help: "New pull request body (pass an empty value to clear it)"
  )
  var body: String?

  @Option(
    name: [.customShort("F"), .long],
    help: "Read the new pull request body from a file ('-' for standard input)"
  )
  var bodyFile: String?

  @Flag(help: "Output the updated pull request record as JSON")
  var json = false

  mutating func validate() throws {
    guard title != nil || body != nil || bodyFile != nil else {
      throw ValidationError("Specify at least one of --title, --body, or --body-file")
    }
    guard body == nil || bodyFile == nil else {
      throw ValidationError("--body and --body-file cannot be used together")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).edit(
        pullRequestURI: pullRequestURI,
        title: title,
        body: body,
        bodyFile: bodyFile,
        json: json
      )
    }
  }
}
