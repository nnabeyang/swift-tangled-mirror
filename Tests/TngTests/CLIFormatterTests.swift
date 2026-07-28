import Foundation
import Testing

@testable import tng

@Suite struct CLIFormatterTests {
  @Test func terminalOutputRendersTablesAndDetails() {
    let formatter = CLIFormatter(
      terminal: CLITerminalContext(
        isTerminal: true,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: true
      )
    )

    let table = formatter.table(
      headers: ["NAME", "STATUS"],
      rows: [["core", "failed"]]
    )
    let details = formatter.details([
      ("Name", "core"),
      ("Status", "failed"),
    ])

    #expect(table.contains("┌"))
    #expect(table.contains("NAME"))
    #expect(table.contains("core"))
    #expect(details.contains("\u{001B}[1mName:"))
    #expect(details.contains("core"))
  }

  @Test func nonTerminalAndNoColorOutputStayPlain() {
    let nonTerminal = CLIFormatter(
      terminal: CLITerminalContext(
        isTerminal: false,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: false
      )
    )
    let noColor = CLIFormatter(
      terminal: CLITerminalContext(
        isTerminal: true,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: false
      )
    )

    #expect(nonTerminal.table(headers: ["NAME"], rows: []).contains("\u{001B}") == false)
    #expect(noColor.details([("Name", "core")]) == "Name: core\n")
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
      terminal: CLITerminalContext(
        isTerminal: true,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: true
      )
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

  @Test func terminalMarkdownWrapsCJKEmojiURLsAndNarrowTables() {
    let formatter = CLIFormatter(
      terminal: CLITerminalContext(
        isTerminal: true,
        viewportWidth: 40,
        markdownWidth: 40,
        colorEnabled: false
      )
    )

    let details = formatter.details(
      [
        (
          "Body",
          "日本語の長い本文 🚀 **重要** https://example.com/a/very/long/path"
        )
      ],
      markdownLabels: ["Body"]
    )
    let table = formatter.table(
      headers: ["NAME", "DESCRIPTION"],
      rows: [["開発 🚀", "長い説明を幅に合わせて折り返します"]],
      markdownColumns: [1]
    )

    #expect(details.contains("重要"))
    #expect(details.contains("**") == false)
    #expect(details.split(separator: "\n").count > 1)
    #expect(table.contains("開発"))
    #expect(table.contains("🚀"))
    #expect(table.split(separator: "\n").allSatisfy { $0.count <= 40 })
  }

  @Test func terminalMarkdownSupportsGFMAndDisablesUntrustedControlSequencesAndOSC8() {
    let formatter = CLIFormatter(
      terminal: CLITerminalContext(
        isTerminal: true,
        viewportWidth: 80,
        markdownWidth: 80,
        colorEnabled: true
      )
    )
    let output = formatter.details(
      [
        (
          "Body",
          """
          # Heading
          - [x] done
          > quote
          ~~old~~ and [safe](https://example.com)
          \u{001B}]8;;https://evil.example\u{0007}evil\u{001B}]8;;\u{0007}
          """
        )
      ],
      markdownLabels: ["Body"]
    )

    #expect(output.contains("Heading"))
    #expect(output.contains("done"))
    #expect(output.contains("quote"))
    #expect(output.contains("\u{001B}]8;") == false)
    #expect(output.contains("\u{0007}") == false)
  }
}

private struct FormatterFixture: Codable, Equatable {
  let name: String
}
