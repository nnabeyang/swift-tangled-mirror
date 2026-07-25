import Foundation
import Testing

@testable import tng

@Suite struct CLIFormatterTests {
  @Test func terminalOutputBoldsOnlyHeadersAndDetailLabels() {
    let formatter = CLIFormatter(
      style: CLIOutputStyle(isTerminal: true, noColor: false)
    )

    let table = formatter.table(
      headers: ["NAME", "STATUS"],
      rows: [["core", "failed"]]
    )
    let details = formatter.details([
      ("Name", "core"),
      ("Status", "failed"),
    ])

    #expect(
      table
        == "\u{001B}[1mNAME\u{001B}[0m\t\u{001B}[1mSTATUS\u{001B}[0m\ncore\tfailed\n"
    )
    #expect(
      details
        == "\u{001B}[1mName\u{001B}[0m\tcore\n\u{001B}[1mStatus\u{001B}[0m\tfailed\n"
    )
  }

  @Test func nonTerminalAndNoColorOutputStayPlain() {
    let nonTerminal = CLIFormatter(
      style: CLIOutputStyle(isTerminal: false, noColor: false)
    )
    let noColor = CLIFormatter(
      style: CLIOutputStyle(isTerminal: true, noColor: true)
    )

    #expect(nonTerminal.table(headers: ["NAME"], rows: []).contains("\u{001B}") == false)
    #expect(noColor.details([("Name", "core")]) == "Name\tcore\n")
  }

  @Test func cellsRemoveLayoutAndANSIControlCharacters() {
    let formatter = CLIFormatter.plain
    let output = formatter.table(
      headers: ["VALUE"],
      rows: [["line\tone\nline\rtwo\u{0007}\u{001B}[31mfailed\u{001B}[0m"]]
    )

    #expect(output == "VALUE\nline one line twofailed\n")
  }

  @Test func JSONNeverContainsFormatterDecoration() throws {
    let formatter = CLIFormatter(
      style: CLIOutputStyle(isTerminal: true, noColor: false)
    )
    let output = try formatter.json(FormatterFixture(name: "core"))

    #expect(output.contains("\u{001B}") == false)
    #expect(try JSONDecoder().decode(FormatterFixture.self, from: Data(output.utf8)).name == "core")
  }

  @Test func cursorDiagnosticUsesOnlyHumanStderrAndEmptyTableKeepsHeader() {
    let formatter = CLIFormatter.plain

    #expect(formatter.cursorDiagnostic("next\npage", json: false) == "Next cursor: next page\n")
    #expect(formatter.cursorDiagnostic("next", json: true).isEmpty)
    #expect(formatter.cursorDiagnostic(nil, json: false).isEmpty)
    #expect(formatter.table(headers: ["NAME"], rows: []) == "NAME\n")
  }
}

private struct FormatterFixture: Codable, Equatable {
  let name: String
}
