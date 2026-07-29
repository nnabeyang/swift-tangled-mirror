import Testing

@testable import tng

@Suite struct CLIDiagnosticFormatterTests {
  private let colored = CLIDiagnosticFormatter(
    terminal: CLITerminalContext(
      isTerminal: true,
      viewportWidth: 80,
      markdownWidth: 80,
      colorEnabled: true
    )
  )

  @Test func warningLabelIsBoldYellowAndTextRemainsPlain() {
    #expect(
      colored.format("warning: results may be incomplete\n")
        == "\u{001B}[1;33mwarning:\u{001B}[0m results may be incomplete\n"
    )
  }

  @Test(
    arguments: [
      "Error:",
      "API error:",
      "Authentication error:",
      "Authentication required:",
      "Git error:",
      "Artifact error:",
      "Pager error:",
      "Pipeline failed:",
      "Unexpected error:",
    ]
  )
  func errorLabelsAreBoldRed(label: String) {
    #expect(
      colored.format("\(label) failure\n")
        == "\u{001B}[1;31m\(label)\u{001B}[0m failure\n"
    )
  }

  @Test func plainOutputPreservesDiagnosticsExactly() {
    let diagnostic = "warning: warning\nAPI error: failure\nNext cursor: next\n"

    #expect(CLIDiagnosticFormatter.plain.format(diagnostic) == diagnostic)
  }

  @Test func onlyKnownLabelsAtTheStartOfEachLineAreDecorated() {
    let diagnostic =
      "warning: first\nNext cursor: warning: cursor\n API error: indented\nAPI error: last\n"

    #expect(
      colored.format(diagnostic)
        == "\u{001B}[1;33mwarning:\u{001B}[0m first\n"
        + "Next cursor: warning: cursor\n"
        + " API error: indented\n"
        + "\u{001B}[1;31mAPI error:\u{001B}[0m last\n"
    )
  }
}
