import ArgumentParser

struct RepoCollaboratorRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a collaborator from a repository"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL")
  var repository: String

  @Argument(help: "Collaborator DID or ATProto handle")
  var collaborator: String

  @Flag(help: "Remove without an interactive confirmation")
  var yes = false

  @Flag(help: "Output a versioned collaborator mutation result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCollaboratorCommandService(formatter: .live).remove(
        repository: repository,
        collaborator: collaborator,
        confirmed: yes,
        json: json
      )
    }
  }
}
