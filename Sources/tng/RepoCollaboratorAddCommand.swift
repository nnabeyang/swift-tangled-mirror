import ArgumentParser

struct RepoCollaboratorAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add a collaborator to a repository"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL")
  var repository: String

  @Argument(help: "Collaborator DID or ATProto handle")
  var collaborator: String

  @Flag(help: "Output a versioned collaborator mutation result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCollaboratorCommandService(formatter: .live).add(
        repository: repository,
        collaborator: collaborator,
        json: json
      )
    }
  }
}
