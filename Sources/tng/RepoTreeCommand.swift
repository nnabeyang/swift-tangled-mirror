import ArgumentParser

struct RepoTreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tree",
    abstract: "List files in a repository tree"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Git branch, tag, or commit (defaults to the repository default branch)")
  var ref: String?

  @Option(help: "Directory path within the repository")
  var path: String?

  @Flag(help: "Output the complete tree as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).tree(
        repository: repository,
        ref: ref,
        path: path,
        json: json
      )
    }
  }
}
