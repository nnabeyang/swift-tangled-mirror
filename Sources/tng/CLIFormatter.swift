import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct CLIOutputStyle: Equatable, Sendable {
  let isTerminal: Bool
  let noColor: Bool

  init(isTerminal: Bool, noColor: Bool) {
    self.isTerminal = isTerminal
    self.noColor = noColor
  }

  var usesANSI: Bool {
    isTerminal && !noColor
  }

  static var live: CLIOutputStyle {
    CLIOutputStyle(
      isTerminal: standardOutputIsTerminal(),
      noColor: ProcessInfo.processInfo.environment.keys.contains("NO_COLOR")
    )
  }
}

struct CLIFormatter: Sendable {
  let style: CLIOutputStyle

  init(style: CLIOutputStyle) {
    self.style = style
  }

  static var live: CLIFormatter {
    CLIFormatter(style: .live)
  }

  static let plain = CLIFormatter(
    style: CLIOutputStyle(isTerminal: false, noColor: false)
  )

  func table(headers: [String], rows: [[String?]]) -> String {
    let header = headers.map { decorateLabel(cell($0)) }.joined(separator: "\t")
    let body = rows.map { row in
      row.map(cell).joined(separator: "\t")
    }
    return ([header] + body).joined(separator: "\n") + "\n"
  }

  func details(_ fields: [(label: String, value: String?)]) -> String {
    fields.map { field in
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

  private func decorateLabel(_ value: String) -> String {
    style.usesANSI ? "\u{001B}[1m\(value)\u{001B}[0m" : value
  }
}

private func standardOutputIsTerminal() -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(FileHandle.standardOutput.fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(FileHandle.standardOutput.fileDescriptor) == 1
  #else
    false
  #endif
}
