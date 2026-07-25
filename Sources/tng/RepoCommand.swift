import ArgumentParser

struct RepoCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "repo",
    abstract: "Work with Tangled repositories",
    subcommands: [
      RepoViewCommand.self,
      RepoListCommand.self,
      RepoTreeCommand.self,
      RepoLogCommand.self,
      RepoBlobCommand.self,
      RepoLanguagesCommand.self,
      RepoArchiveCommand.self,
      RepoBranchCommand.self,
      RepoTagCommand.self,
      RepoStarCommand.self,
      RepoUnstarCommand.self,
    ]
  )
}
