import ArgumentParser

struct AuthSetupGitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "setup-git",
    abstract: "Configure Git HTTPS authentication for a Tangled repository"
  )

  @Option(help: "Git remote to configure")
  var remote = "origin"

  @Flag(help: "Show the planned configuration without changing it")
  var dryRun = false

  @Flag(help: "Replace a conflicting repository-local credential helper")
  var replaceExistingHelper = false

  @Flag(help: "Output the result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      let result = try await AuthGitCommandService().setup(
        remote: remote,
        dryRun: dryRun,
        replaceExistingHelper: replaceExistingHelper,
        explicitAccount: CLIAccountOverride.identifier
      )
      if json { return CLICommandOutput(stdout: try CLIFormatter.live.json(result)) }
      let action = result.dryRun ? "Would configure" : (result.changed ? "Configured" : "Already configured")
      return CLICommandOutput(
        stdout: "\(action) \(result.remote) for @\(result.accountHandle) (\(result.accountDID))\nURL: \(result.url)\n"
      )
    }
  }
}
