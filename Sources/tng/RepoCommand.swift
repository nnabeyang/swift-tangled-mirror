import ArgumentParser

struct RepoCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "repo",
    abstract: "Work with Tangled repositories",
    subcommands: [
      RepoCreateCommand.self,
      RepoDeleteCommand.self,
      RepoViewCommand.self,
      RepoListCommand.self,
      RepoTreeCommand.self,
      RepoLogCommand.self,
      RepoBlobCommand.self,
      RepoLanguagesCommand.self,
      RepoArchiveCommand.self,
      RepoCollaboratorCommand.self,
      RepoBranchCommand.self,
      RepoTagCommand.self,
      RepoStarCommand.self,
      RepoUnstarCommand.self,
    ]
  )
}
