import Foundation
import Swiftdansi

struct CLIFormatter: Sendable {
  let terminal: CLITerminalContext

  init(terminal: CLITerminalContext) {
    self.terminal = terminal
  }

  static var live: CLIFormatter {
    CLIFormatter(terminal: .live)
  }

  static let plain = CLIFormatter(terminal: .plain)

  func table(
    headers: [String],
    rows: [[String?]],
    markdownColumns: Set<Int> = []
  ) -> String {
    if terminal.isTerminal {
      let header = "| " + headers.map { markdownCell($0) }.joined(separator: " | ") + " |"
      let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
      let body = rows.map { row in
        let cells = headers.indices.map { index in
          let value = index < row.count ? row[index] : nil
          return markdownColumns.contains(index)
            ? markdownTableContent(value)
            : markdownCell(cell(value))
        }
        return "| " + cells.joined(separator: " | ") + " |"
      }
      return renderMarkdown(([header, separator] + body).joined(separator: "\n"))
    }

    let header = headers.map { decorateLabel(cell($0)) }.joined(separator: "\t")
    let body = rows.map { row in
      row.map(cell).joined(separator: "\t")
    }
    return ([header] + body).joined(separator: "\n") + "\n"
  }

  func details(
    _ fields: [(label: String, value: String?)],
    markdownLabels: Set<String> = []
  ) -> String {
    if terminal.isTerminal {
      let markdown = fields.map { field in
        if markdownLabels.contains(field.label) {
          return
            "**\(markdownCell(field.label)):**\n\n\(markdownContent(field.value))"
        }
        return "**\(markdownCell(field.label)):** \(markdownCell(cell(field.value)))"
      }.joined(separator: "\n\n")
      return renderMarkdown(markdown)
    }

    return fields.map { field in
      "\(decorateLabel(cell(field.label)))\t\(cell(field.value))"
    }.joined(separator: "\n") + "\n"
  }

  func json<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  func jsonLine<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  func cursorDiagnostic(_ cursor: String?, json: Bool) -> String {
    guard !json, let cursor else { return "" }
    return "Next cursor: \(cell(cursor))\n"
  }

  func cell(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "-" }
    var result = String.UnicodeScalarView()
    var escapeState = 0
    for scalar in value.unicodeScalars {
      if escapeState == 1 {
        escapeState = scalar.value == 0x5B ? 2 : 0
        continue
      }
      if escapeState == 2 {
        if (0x40 ... 0x7E).contains(scalar.value) {
          escapeState = 0
        }
        continue
      }
      if scalar.value == 0x1B {
        escapeState = 1
      } else if scalar == "\t" || scalar == "\r" || scalar == "\n" {
        result.append(" ")
      } else if scalar.value >= 0x20, scalar.value != 0x7F,
        !(0x80 ... 0x9F).contains(scalar.value)
      {
        result.append(scalar)
      }
    }
    let sanitized = String(result)
    return sanitized.isEmpty ? "-" : sanitized
  }

  private func renderMarkdown(_ markdown: String) -> String {
    let output = Swiftdansi.render(
      markdown,
      options: RenderOptions(
        wrap: true,
        width: terminal.markdownWidth,
        hyperlinks: false,
        color: terminal.colorEnabled,
        theme: .default,
        tableBorder: .unicode,
        tablePadding: 0,
        tableDense: false,
        tableTruncate: true
      )
    )
    return output.hasSuffix("\n") ? output : output + "\n"
  }

  private func markdownContent(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "-" }
    let sanitized = sanitize(value, preserveNewlines: true)
    return sanitized.isEmpty ? "-" : sanitized
  }

  private func markdownTableContent(_ value: String?) -> String {
    markdownContent(value)
      .replacingOccurrences(of: "\n", with: "<br>")
      .replacingOccurrences(of: "|", with: "\\|")
  }

  private func markdownCell(_ value: String) -> String {
    var result = value.replacingOccurrences(of: "\\", with: "\\\\")
    for character in ["`", "*", "_", "{", "}", "[", "]", "<", ">", "(", ")", "#", "+", "-", ".", "!", "|"] {
      result = result.replacingOccurrences(of: character, with: "\\\(character)")
    }
    return result
  }

  private func sanitize(_ value: String, preserveNewlines: Bool) -> String {
    var result = String.UnicodeScalarView()
    var escapeState = 0
    for scalar in value.unicodeScalars {
      if escapeState == 1 {
        escapeState = scalar.value == 0x5B ? 2 : 0
        continue
      }
      if escapeState == 2 {
        if (0x40 ... 0x7E).contains(scalar.value) {
          escapeState = 0
        }
        continue
      }
      if scalar.value == 0x1B {
        escapeState = 1
      } else if scalar == "\n", preserveNewlines {
        result.append(scalar)
      } else if scalar == "\t" || scalar == "\r" || scalar == "\n" {
        result.append(" ")
      } else if scalar.value >= 0x20, scalar.value != 0x7F,
        !(0x80 ... 0x9F).contains(scalar.value)
      {
        result.append(scalar)
      }
    }
    return String(result)
  }

  private func decorateLabel(_ value: String) -> String {
    terminal.colorEnabled ? "\u{001B}[1m\(value)\u{001B}[0m" : value
  }
}
