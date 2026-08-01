import ArgumentParser

struct RepoCollaboratorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "collaborator",
    abstract: "Manage repository collaborators",
    subcommands: [
      RepoCollaboratorListCommand.self,
      RepoCollaboratorAddCommand.self,
      RepoCollaboratorRemoveCommand.self,
    ]
  )
}
