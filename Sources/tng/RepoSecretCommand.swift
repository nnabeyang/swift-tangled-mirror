import ArgumentParser

struct RepoSecretCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "secret",
    abstract: "Manage repository CI secrets",
    subcommands: [
      RepoSecretListCommand.self,
      RepoSecretAddCommand.self,
      RepoSecretRemoveCommand.self,
    ]
  )
}
