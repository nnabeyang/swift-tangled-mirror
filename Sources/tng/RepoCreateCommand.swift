import ArgumentParser

struct RepoCreateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a Tangled repository"
  )

  @Argument(help: "Repository name")
  var name: String

  @Option(help: "Knot host or HTTPS endpoint")
  var knot: String

  @Option(help: "Default Git branch")
  var defaultBranch = "main"

  @Option(help: "Git clone URL to import or fork")
  var source: String?

  @Option(help: "Custom did:web repository DID")
  var repoDID: String?

  @Flag(help: "Output a versioned repository creation result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).create(
        name: name,
        knot: knot,
        defaultBranch: defaultBranch,
        source: source,
        repositoryDID: repoDID,
        json: json
      )
    }
  }
}
