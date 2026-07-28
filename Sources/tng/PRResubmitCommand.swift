import ArgumentParser

struct PRResubmitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resubmit",
    abstract: "Add a round from an updated branch or patch file"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Option(help: "Read a cumulative git diff or git format-patch from this file")
  var patchFile: String?

  @Flag(help: "Resubmit the complete dependent pull request stack")
  var stack = false

  @Flag(help: "Show the stack operation plan without writing")
  var dryRun = false

  @Flag(help: "Allow deletion of pull request records in a stack")
  var yes = false

  @Flag(help: "Output the updated pull request and round as JSON")
  var json = false

  mutating func validate() throws {
    guard stack || (!dryRun && !yes) else {
      throw ValidationError("--dry-run and --yes require --stack")
    }
    guard !(dryRun && yes) else {
      throw ValidationError("--dry-run cannot be combined with --yes")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).resubmit(
        pullRequestURI: pullRequestURI,
        patchFile: patchFile,
        stack: stack,
        dryRun: dryRun,
        confirmed: yes,
        json: json
      )
    }
  }
}
