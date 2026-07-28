import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct CLIProcessTests {
  @Test func versionAndHelpWriteSuccessfulOutputToStdout() throws {
    let version = try TngProcess.run(["--version"])
    let help = try TngProcess.run(["--help"])

    #expect(version.status == 0)
    #expect(version.stdout == "\(SwiftTangled.version)\n")
    #expect(version.stderr.isEmpty)
    #expect(help.status == 0)
    #expect(help.stdout.contains("Exit status:"))
    #expect(help.stdout.contains("64  Invalid command usage"))
    #expect(help.stdout.contains("api"))
    #expect(help.stdout.contains("events"))
    #expect(help.stdout.contains("completion"))
    #expect(help.stdout.contains("capabilities"))
    #expect(help.stdout.contains("artifact"))
    #expect(help.stderr.isEmpty)
  }

  @Test func capabilitiesProvideHumanAndVersionedJSONOutput() throws {
    let human = try TngProcess.run(["capabilities"])
    let json = try TngProcess.run(["capabilities", "--json"])

    #expect(human.status == 0)
    #expect(human.stdout.contains("COMMAND"))
    #expect(human.stdout.contains("pr create"))
    #expect(human.stdout.contains("pr resubmit"))
    #expect(human.stderr.isEmpty)

    #expect(json.status == 0)
    let document = try JSONDecoder().decode(
      CapabilityDocument.self,
      from: Data(json.stdout.utf8)
    )
    #expect(document.schemaVersion == 1)
    #expect(document.commands.contains { $0.path == ["capabilities"] })
    #expect(json.stderr.isEmpty)
  }

  @Test func terminalEnvironmentControlsOnlyHumanDecoration() throws {
    let plain = try TngProcess.run(
      ["capabilities"],
      environment: [
        "NO_COLOR": "",
        "CLICOLOR": "1",
        "CLICOLOR_FORCE": "0",
      ]
    )
    let forcedTTY = try TngProcess.run(
      ["capabilities"],
      environment: [
        "NO_COLOR": "",
        "CLICOLOR": "1",
        "CLICOLOR_FORCE": "0",
        "TNG_FORCE_TTY": "40",
      ]
    )
    let forcedColor = try TngProcess.run(
      ["capabilities"],
      environment: [
        "NO_COLOR": "",
        "CLICOLOR": "1",
        "CLICOLOR_FORCE": "1",
      ]
    )
    let disabled = try TngProcess.run(
      ["capabilities"],
      environment: [
        "NO_COLOR": "1",
        "CLICOLOR_FORCE": "1",
        "TNG_FORCE_TTY": "40",
      ]
    )
    let json = try TngProcess.run(
      ["capabilities", "--json"],
      environment: [
        "NO_COLOR": "",
        "CLICOLOR_FORCE": "1",
        "TNG_FORCE_TTY": "40",
      ]
    )

    #expect(plain.stdout.contains("\u{001B}") == false)
    #expect(forcedTTY.stdout.contains("\u{001B}"))
    #expect(forcedTTY.stdout.contains("COMMAND"))
    #expect(forcedColor.stdout.contains("\u{001B}"))
    #expect(forcedColor.stdout.contains("COMMAND"))
    #expect(disabled.stdout.contains("\u{001B}") == false)
    #expect(json.stdout.contains("\u{001B}") == false)
    #expect(
      try JSONDecoder().decode(CapabilityDocument.self, from: Data(json.stdout.utf8))
        .schemaVersion == 1
    )
  }

  @Test func jsonModeReturnsStructuredOperationalAndUsageErrors() throws {
    let api = try TngProcess.run(["repo", "view", "not-valid", "--json"])
    let usage = try TngProcess.run(["repo", "list", "--limit", "0", "--json"])

    #expect(api.status == CLIExitCode.api.rawValue)
    #expect(api.stdout.isEmpty)
    #expect(api.stderr.contains("\"category\":\"api\""))
    #expect(api.stderr.contains("\"code\":\"invalid_request\""))
    #expect(api.stderr.contains("\"schemaVersion\":1"))

    #expect(usage.status == CLIExitCode.usage.rawValue)
    #expect(usage.stdout.isEmpty)
    #expect(usage.stderr.contains("\"category\":\"usage\""))
    #expect(usage.stderr.contains("\"code\":\"invalid_usage\""))
    #expect(usage.stderr.contains("\"exitCode\":64"))
  }

  @Test func completionCommandGeneratesScriptsFromTheArgumentParserCommandTree() throws {
    let cases = [
      (shell: "bash", marker: "#!/bin/bash"),
      (shell: "zsh", marker: "#compdef tng"),
      (shell: "fish", marker: "complete -c 'tng'"),
    ]

    for testCase in cases {
      let command = try TngProcess.run(["completion", testCase.shell])
      let builtIn = try TngProcess.run(["--generate-completion-script", testCase.shell])

      #expect(command.status == 0)
      #expect(command.stdout == builtIn.stdout)
      #expect(command.stdout.contains(testCase.marker))
      #expect(command.stderr.isEmpty)
    }
  }

  @Test func completionScriptsIncludeCommandsOptionsAndStaticValues() throws {
    let result = try TngProcess.run(["completion", "zsh"])

    #expect(result.status == 0)
    for value in [
      "repo", "issue", "pr", "events", "api", "completion",
      "artifact", "upload", "download", "delete",
      "branch", "tag", "languages", "archive",
      "--state", "--status", "--sort", "--format", "--content-type", "--yes",
      "open", "closed", "merged", "asc", "desc", "tar.gz", "zip",
      "sh.tangled.actor.getProfile",
    ] {
      #expect(result.stdout.contains(value))
    }
    #expect(result.stderr.isEmpty)
  }

  @Test func completionHelpDocumentsInstallationAndRejectsUnsupportedShells() throws {
    let help = try TngProcess.run(["completion", "--help"])
    let unsupported = try TngProcess.run(["completion", "powershell"])

    #expect(help.status == 0)
    #expect(help.stdout.contains("tng completion bash"))
    #expect(help.stdout.contains("tng completion zsh"))
    #expect(help.stdout.contains("tng completion fish"))
    #expect(help.stdout.contains("~/.bashrc"))
    #expect(help.stdout.contains("compinit"))
    #expect(help.stderr.isEmpty)
    #expect(unsupported.status == CLIExitCode.usage.rawValue)
    #expect(unsupported.stdout.isEmpty)
    #expect(unsupported.stderr.contains("powershell"))
    #expect(unsupported.stderr.contains("Please provide one of 'bash', 'zsh' or 'fish'"))
  }

  @Test func authLoginHelpDocumentsDesktopAndHeadlessModes() throws {
    let help = try TngProcess.run(["auth", "login", "--help"])

    #expect(help.status == 0)
    #expect(help.stdout.contains("--no-browser"))
    #expect(help.stdout.contains("--callback-port"))
    #expect(help.stderr.isEmpty)
  }

  @Test func artifactListHelpDescribesItsIntegratedPaginationCursor() throws {
    let help = try TngProcess.run(["artifact", "list", "--help"])

    #expect(help.status == 0)
    #expect(help.stdout.contains("Pagination cursor from a previous response"))
    #expect(!help.stdout.contains("Bobbin cursor from a previous response"))
    #expect(help.stderr.isEmpty)
  }

  @Test func headlessAuthRequiresAValidFixedCallbackPort() throws {
    let missing = try TngProcess.run([
      "auth", "login", "alice.example", "--no-browser",
    ])
    let zero = try TngProcess.run([
      "auth", "login", "alice.example", "--callback-port", "0",
    ])

    #expect(missing.status == CLIExitCode.usage.rawValue)
    #expect(missing.stdout.isEmpty)
    #expect(missing.stderr.contains("--callback-port is required with --no-browser"))
    #expect(zero.status == CLIExitCode.usage.rawValue)
    #expect(zero.stdout.isEmpty)
    #expect(zero.stderr.contains("--callback-port must be between 1 and 65535"))
  }

  @Test func APIAndGitFailuresUseDedicatedExitCodes() throws {
    let api = try TngProcess.run(["repo", "view", "not-valid"])
    let directory = try TemporaryDirectory()
    let git = try TngProcess.run(["repo", "view"], currentDirectory: directory.url)

    #expect(api.status == CLIExitCode.api.rawValue)
    #expect(api.stdout.isEmpty)
    #expect(api.stderr.hasPrefix("API error: invalid request:"))
    #expect(git.status == CLIExitCode.git.rawValue)
    #expect(git.stdout.isEmpty)
    #expect(git.stderr.hasPrefix("Git error:"))

    let rejectedQuery = try TngProcess.run(["api", "com.atproto.repo.putRecord"])
    #expect(rejectedQuery.status == CLIExitCode.api.rawValue)
    #expect(rejectedQuery.stdout.isEmpty)
    #expect(rejectedQuery.stderr.contains("unsupported Bobbin query NSID"))
  }

  #if !canImport(Security)
    @Test func LinuxAuthenticationUsesXDGSessionStorage() throws {
      let directory = try TemporaryDirectory()
      let environment = ["XDG_STATE_HOME": directory.url.path]
      let status = try TngProcess.run(["auth", "status"], environment: environment)
      let logout = try TngProcess.run(["auth", "logout"], environment: environment)

      #expect(status.status == CLIExitCode.authentication.rawValue)
      #expect(status.stdout.isEmpty)
      #expect(
        status.stderr
          == "Authentication required: run 'tng auth login <handle>' to sign in\n"
      )
      #expect(logout.status == 0)
      #expect(logout.stdout.isEmpty)
      #expect(logout.stderr == "Not signed in; nothing to log out.\n")
    }
  #endif

  @Test func RepresentativeCommandsUseArgumentParserUsageExitCode() throws {
    let cases: [([String], String)] = [
      (["repo", "list", "--limit", "0"], "--limit must be between 1 and 1000"),
      (["issue", "list", "--state", "invalid"], "--state must be open or closed"),
      (["pr", "list", "--status", "invalid"], "--status must be open, closed, or merged"),
      (["auth", "login"], "Missing expected argument '<handle>'"),
      (["repo", "archive"], "--output"),
      (["api", "sh.tangled.actor.getProfile", "-f", "missing-separator"], "<field>"),
    ]

    for (arguments, diagnostic) in cases {
      let result = try TngProcess.run(arguments)
      #expect(result.status == CLIExitCode.usage.rawValue)
      #expect(result.stdout.isEmpty)
      #expect(result.stderr.contains(diagnostic))
      #expect(result.stderr.contains("Usage:"))
    }
  }
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-tangled-process-tests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
