import ArgumentParser

struct AuthCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth",
    abstract: "Manage tng authentication",
    subcommands: [
      AuthLoginCommand.self,
      AuthListCommand.self,
      AuthSwitchCommand.self,
      AuthStatusCommand.self,
      AuthLogoutCommand.self,
      AuthSetupGitCommand.self,
      AuthGitCredentialCommand.self,
      AuthAgentCommand.self,
    ]
  )
}
