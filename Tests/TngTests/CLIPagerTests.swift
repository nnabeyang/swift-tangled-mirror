import Foundation
import Testing

@testable import tng

@Suite struct CLIPagerTests {
  @Test func commandUsesTNGPagerThenPagerAndTreatsEmptyValuesAsDisabled() {
    #expect(
      CLIPager.command(
        environment: [
          "TNG_PAGER": "less -R",
          "PAGER": "more",
        ]
      ) == "less -R"
    )
    #expect(
      CLIPager.command(
        environment: [
          "TNG_PAGER": "",
          "PAGER": "more",
        ]
      ) == nil
    )
    #expect(CLIPager.command(environment: ["TNG_PAGER": "", "PAGER": ""]) == nil)
    #expect(CLIPager.command(environment: [:]) == "less")
    #expect(CLIPager.command(environment: ["TERM": "dumb"]) == nil)
  }

  @Test func pagerEnvironmentAddsOnlyMissingDefaults() {
    let defaults = CLIPager.pagerEnvironment(["PATH": "/bin"])
    #expect(defaults["LESS"] == "FRX")
    #expect(defaults["LV"] == "-c")
    #expect(defaults["PATH"] == "/bin")

    let configured = CLIPager.pagerEnvironment([
      "LESS": "",
      "LV": "-Ou8",
    ])
    #expect(configured["LESS"] == "")
    #expect(configured["LV"] == "-Ou8")
  }

  @Test func writerPagesOnlyEligibleTerminalOutput() throws {
    let recorder = PagerRecorder()
    let writer = outputWriter(recorder: recorder, terminal: true, pager: "pager --flag")

    writer.write(CLICommandOutput(stdout: "paged\n", stderr: "warning\n", isPageable: true))
    writer.write(CLICommandOutput(stdout: "direct\n"))

    #expect(recorder.pagerCommands == ["pager --flag"])
    #expect(recorder.pagerInputs == [Data("paged\n".utf8)])
    #expect(recorder.pagerEnvironments[0]["LESS"] == "FRX")
    #expect(recorder.pagerEnvironments[0]["LV"] == "-c")
    #expect(recorder.stdout == Data("direct\n".utf8))
    #expect(recorder.stderr == Data("warning\n".utf8))
  }

  @Test func writerUsesDefaultPagerForEligibleTerminalOutput() {
    let recorder = PagerRecorder()
    outputWriter(recorder: recorder, terminal: true, pager: nil)
      .write(CLICommandOutput(stdout: "default\n", isPageable: true))

    #expect(recorder.pagerCommands == ["less"])
    #expect(recorder.pagerInputs == [Data("default\n".utf8)])
    #expect(recorder.stdout.isEmpty)
  }

  @Test func writerBypassesPagerForNonTerminalDisabledAndCatConfigurations() {
    let nonTerminal = PagerRecorder()
    outputWriter(recorder: nonTerminal, terminal: false, pager: "less")
      .write(CLICommandOutput(stdout: "plain\n", isPageable: true))
    #expect(nonTerminal.pagerCommands.isEmpty)
    #expect(nonTerminal.stdout == Data("plain\n".utf8))

    let disabled = PagerRecorder()
    outputWriter(recorder: disabled, terminal: true, pager: "")
      .write(CLICommandOutput(stdout: "disabled\n", isPageable: true))
    #expect(disabled.pagerCommands.isEmpty)
    #expect(disabled.stdout == Data("disabled\n".utf8))

    let cat = PagerRecorder()
    outputWriter(recorder: cat, terminal: true, pager: "cat")
      .write(CLICommandOutput(stdout: "cat\n", isPageable: true))
    #expect(cat.pagerCommands.isEmpty)
    #expect(cat.stdout == Data("cat\n".utf8))
  }

  @Test func writerPagesWhenTerminalOutputIsForced() {
    let recorder = PagerRecorder()
    let terminal = CLITerminalContext.resolve(
      environment: ["TNG_FORCE_TTY": "80"],
      outputIsTerminal: false,
      detectedWidth: nil
    )
    let writer = CLIOutputWriter(
      terminal: terminal,
      environment: ["TNG_PAGER": "less"],
      pager: CLIPager { command, data, environment in
        recorder.pagerCommands.append(command)
        recorder.pagerInputs.append(data)
        recorder.pagerEnvironments.append(environment)
      },
      stdout: { recorder.stdout.append($0) },
      stderr: { recorder.stderr.append($0) }
    )

    writer.write(CLICommandOutput(stdout: "forced\n", isPageable: true))

    #expect(recorder.pagerCommands == ["less"])
    #expect(recorder.pagerInputs == [Data("forced\n".utf8)])
    #expect(recorder.stdout.isEmpty)
  }

  @Test(
    arguments: [
      CLIPagerError.launch(command: "missing-pager", message: "not found"),
      CLIPagerError.exit(command: "missing-pager", status: 127),
    ]
  )
  func writerFallsBackToDirectOutputWhenPagerIsUnavailable(error: CLIPagerError) {
    let recorder = PagerRecorder()
    let writer = failingOutputWriter(recorder: recorder, error: error)

    writer.write(
      CLICommandOutput(
        stdout: "result\n",
        stderr: "command warning\n",
        isPageable: true
      )
    )

    #expect(recorder.stdout == Data("result\n".utf8))
    #expect(recorder.stderr == Data("command warning\n\(error.warning)".utf8))
  }

  @Test(
    arguments: [
      CLIPagerError.write(command: "pager", message: "closed input"),
      CLIPagerError.exit(command: "pager", status: 2),
      CLIPagerError.signal(command: "pager", signal: 15),
    ]
  )
  func writerWarnsWithoutRepeatingOutputAfterPagerStarts(error: CLIPagerError) {
    let recorder = PagerRecorder()
    let writer = failingOutputWriter(recorder: recorder, error: error)

    writer.write(CLICommandOutput(stdout: "result\n", isPageable: true))

    #expect(recorder.stdout.isEmpty)
    #expect(
      recorder.stderr
        == Data("warning: pager failed: \(error); output may be incomplete\n".utf8)
    )
  }

  @Test func writerUsesStderrDiagnosticContextIndependentlyFromStdout() {
    let recorder = PagerRecorder()
    let stderrTerminal = CLITerminalContext(
      isTerminal: true,
      viewportWidth: 80,
      markdownWidth: 80,
      colorEnabled: true
    )
    let writer = CLIOutputWriter(
      terminal: .plain,
      diagnosticFormatter: CLIDiagnosticFormatter(terminal: stderrTerminal),
      environment: [:],
      pager: CLIPager { _, _, _ in },
      stdout: { recorder.stdout.append($0) },
      stderr: { recorder.stderr.append($0) }
    )

    writer.write(
      CLICommandOutput(
        stdout: "plain stdout\n",
        stderr: "warning: styled stderr\n"
      )
    )

    #expect(recorder.stdout == Data("plain stdout\n".utf8))
    #expect(
      recorder.stderr
        == Data("\u{001B}[1;33mwarning:\u{001B}[0m styled stderr\n".utf8)
    )
  }

  @Test func liveProcessWritesDataAndConfiguredEnvironment() throws {
    let directory = try PagerTemporaryDirectory()
    let output = directory.url.appendingPathComponent("output")
    let environment = directory.url.appendingPathComponent("environment")
    let command =
      "printf '%s|%s' \"$LESS\" \"$LV\" > \(shellQuote(environment.path)); "
      + "cat > \(shellQuote(output.path))"

    try CLIPager.runProcess(
      command: command,
      data: Data("pager input\n".utf8),
      environment: CLIPager.pagerEnvironment([:])
    )

    #expect(try Data(contentsOf: output) == Data("pager input\n".utf8))
    #expect(try String(contentsOf: environment, encoding: .utf8) == "FRX|-c")
  }

  @Test(
    arguments: [
      "exit 0",
      "head -c 1 >/dev/null",
    ]
  )
  func liveProcessAcceptsEarlyExitAndBrokenPipe(command: String) throws {
    try CLIPager.runProcess(
      command: command,
      data: Data(repeating: 0x61, count: 2 * 1024 * 1024),
      environment: [:]
    )
  }

  @Test(
    arguments: [
      ("exit 7", Int32(7)),
      ("command-that-does-not-exist", Int32(127)),
    ]
  )
  func liveProcessRejectsUnsuccessfulCommands(command: String, status: Int32) {
    #expect(
      throws: CLIPagerError.exit(command: command, status: status)
    ) {
      try CLIPager.runProcess(
        command: command,
        data: Data(),
        environment: [:]
      )
    }
  }

  @Test func pagerErrorsUseUnexpectedExitAndStableJSONCode() {
    let error = CLIPagerError.exit(command: "pager", status: 2)
    let report = errorReport(for: error)
    let json = jsonErrorReport(for: error)

    #expect(report.exitCode == .unexpected)
    #expect(report.diagnostic == "Pager error: 'pager' exited with status 2\n")
    #expect(json.category == "unexpected")
    #expect(json.code == "pager_error")
  }

  private func outputWriter(
    recorder: PagerRecorder,
    terminal: Bool,
    pager: String?
  ) -> CLIOutputWriter {
    CLIOutputWriter(
      terminal: CLITerminalContext(
        isTerminal: terminal,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: terminal
      ),
      environment: pager.map { ["TNG_PAGER": $0] } ?? [:],
      pager: CLIPager { command, data, environment in
        recorder.pagerCommands.append(command)
        recorder.pagerInputs.append(data)
        recorder.pagerEnvironments.append(environment)
      },
      stdout: { recorder.stdout.append($0) },
      stderr: { recorder.stderr.append($0) }
    )
  }

  private func failingOutputWriter(
    recorder: PagerRecorder,
    error: CLIPagerError
  ) -> CLIOutputWriter {
    CLIOutputWriter(
      terminal: CLITerminalContext(
        isTerminal: true,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: true
      ),
      environment: ["TNG_PAGER": "pager"],
      pager: CLIPager { _, _, _ in throw error },
      stdout: { recorder.stdout.append($0) },
      stderr: { recorder.stderr.append($0) }
    )
  }
}

private final class PagerRecorder: @unchecked Sendable {
  var pagerCommands: [String] = []
  var pagerInputs: [Data] = []
  var pagerEnvironments: [[String: String]] = []
  var stdout = Data()
  var stderr = Data()
}

private final class PagerTemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-tangled-pager-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

private func shellQuote(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}
