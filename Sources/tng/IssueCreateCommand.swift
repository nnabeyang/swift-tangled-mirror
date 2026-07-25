import ArgumentParser

struct IssueCreateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a Tangled issue"
  )

  @Option(help: "Target repository (defaults to Git origin)")
  var repo: String?

  @Option(help: "Issue title")
  var title: String

  @Option(help: "Issue body")
  var body: String?

  @Option(help: "Read the issue body from a file")
  var bodyFile: String?

  @Flag(help: "Output the created issue record as JSON")
  var json = false

  mutating func validate() throws {
    guard body == nil || bodyFile == nil else {
      throw ValidationError("--body and --body-file cannot be used together")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await IssueCommandService(formatter: .live).create(
        repository: repo,
        title: title,
        body: body,
        bodyFile: bodyFile,
        json: json
      )
    }
  }
}
