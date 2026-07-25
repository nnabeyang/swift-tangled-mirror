import ArgumentParser

struct RepoTagCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tag",
    abstract: "Work with repository tags",
    subcommands: [RepoTagListCommand.self]
  )
}
