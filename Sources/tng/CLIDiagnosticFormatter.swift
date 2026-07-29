import Foundation

struct CLIDiagnosticFormatter: Sendable {
  private static let warningLabels = [
    "warning:"
  ]

  private static let errorLabels = [
    "Authentication required:",
    "Authentication error:",
    "Unexpected error:",
    "Artifact error:",
    "Pipeline failed:",
    "Pager error:",
    "API error:",
    "Git error:",
    "Error:",
  ]

  let colorEnabled: Bool

  init(terminal: CLITerminalContext) {
    self.colorEnabled = terminal.colorEnabled
  }

  static var live: CLIDiagnosticFormatter {
    CLIDiagnosticFormatter(terminal: .standardError)
  }

  static let plain = CLIDiagnosticFormatter(terminal: .plain)

  func format(_ diagnostic: String) -> String {
    guard colorEnabled else { return diagnostic }
    return diagnostic.split(separator: "\n", omittingEmptySubsequences: false)
      .map { decorateLabel(in: String($0)) }
      .joined(separator: "\n")
  }

  private func decorateLabel(in line: String) -> String {
    if let label = Self.warningLabels.first(where: line.hasPrefix) {
      return decorate(label, color: 33) + line.dropFirst(label.count)
    }
    if let label = Self.errorLabels.first(where: line.hasPrefix) {
      return decorate(label, color: 31) + line.dropFirst(label.count)
    }
    return line
  }

  private func decorate(_ label: String, color: Int) -> String {
    "\u{001B}[1;\(color)m\(label)\u{001B}[0m"
  }
}
