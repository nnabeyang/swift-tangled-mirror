import ArgumentParser

struct AuthAgentCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agent",
    abstract: "Run the host OAuth auth-agent",
    subcommands: [AuthAgentServeCommand.self, AuthAgentServiceCommand.self]
  )
}
