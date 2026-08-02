import ArgumentParser

struct RepoBranchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "branch",
    abstract: "Work with repository branches",
    subcommands: [RepoBranchListCommand.self, RepoBranchSetDefaultCommand.self]
  )
}
