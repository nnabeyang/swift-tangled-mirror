import ArgumentParser

struct PRCreateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a pull request from a pushed branch"
  )

  @Option(help: "Target repository (defaults to Git origin)")
  var repo: String?

  @Option(help: "Target branch (defaults to the repository default branch)")
  var base: String?

  @Option(help: "Source branch (defaults to the current local branch)")
  var head: String?

  @Option(help: "Pull request title (defaults to the first commit subject)")
  var title: String?

  @Option(help: "Pull request body")
  var body: String?

  @Option(help: "Read the pull request body from a file")
  var bodyFile: String?

  @Flag(help: "Output the created pull request as JSON")
  var json = false

  mutating func validate() throws {
    guard body == nil || bodyFile == nil else {
      throw ValidationError("--body and --body-file cannot be used together")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).create(
        repository: repo,
        base: base,
        head: head,
        title: title,
        body: body,
        bodyFile: bodyFile,
        json: json
      )
    }
  }
}
