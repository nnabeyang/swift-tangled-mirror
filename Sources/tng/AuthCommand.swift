import ArgumentParser

struct AuthCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth",
    abstract: "Manage tng authentication",
    subcommands: [
      AuthLoginCommand.self,
      AuthStatusCommand.self,
      AuthLogoutCommand.self,
      AuthAgentCommand.self,
    ]
  )
}
