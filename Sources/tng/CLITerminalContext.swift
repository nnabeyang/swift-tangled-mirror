import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct CLITerminalContext: Equatable, Sendable {
  static let defaultViewportWidth = 80
  static let defaultMarkdownWidth = 120

  let isTerminal: Bool
  let viewportWidth: Int
  let markdownWidth: Int
  let colorEnabled: Bool

  static var live: CLITerminalContext {
    resolve(
      environment: ProcessInfo.processInfo.environment,
      outputIsTerminal: standardOutputIsTerminal(),
      detectedWidth: detectedTerminalWidth()
    )
  }

  static let plain = CLITerminalContext(
    isTerminal: false,
    viewportWidth: defaultViewportWidth,
    markdownWidth: defaultViewportWidth,
    colorEnabled: false
  )

  static func resolve(
    environment: [String: String],
    outputIsTerminal: Bool,
    detectedWidth: Int?
  ) -> CLITerminalContext {
    let detectedWidth = positive(detectedWidth) ?? defaultViewportWidth
    let forceTTY = nonempty(environment["TNG_FORCE_TTY"])
    let isTerminal = outputIsTerminal || forceTTY != nil
    let viewportWidth = forcedWidth(forceTTY, detectedWidth: detectedWidth) ?? detectedWidth
    let markdownLimit =
      positive(environment["TNG_MDWIDTH"].flatMap(Int.init))
      ?? defaultMarkdownWidth
    let colorDisabled =
      nonempty(environment["NO_COLOR"]) != nil
      || environment["CLICOLOR"] == "0"
    let colorForced =
      nonempty(environment["CLICOLOR_FORCE"]).map { $0 != "0" }
      ?? false

    return CLITerminalContext(
      isTerminal: isTerminal,
      viewportWidth: viewportWidth,
      markdownWidth: min(viewportWidth, markdownLimit),
      colorEnabled: !colorDisabled && (colorForced || isTerminal)
    )
  }

  private static func forcedWidth(_ specification: String?, detectedWidth: Int) -> Int? {
    guard let specification else { return nil }
    if let width = positive(Int(specification)) {
      return width
    }
    guard specification.hasSuffix("%"),
      let percentage = positive(Int(specification.dropLast()))
    else {
      return nil
    }

    let scaled = (Double(detectedWidth) * Double(percentage) / 100).rounded(.down)
    guard scaled < Double(Int.max) else { return Int.max }
    return max(1, Int(scaled))
  }

  private static func positive(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return value
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
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

private func detectedTerminalWidth() -> Int? {
  let standardOutput = FileHandle.standardOutput.fileDescriptor
  if let width = terminalWidth(fileDescriptor: standardOutput) {
    return width
  }

  #if canImport(Darwin)
    let terminal = Darwin.open("/dev/tty", O_RDONLY)
    guard terminal >= 0 else { return nil }
    defer { Darwin.close(terminal) }
  #elseif canImport(Glibc)
    let terminal = Glibc.open("/dev/tty", O_RDONLY)
    guard terminal >= 0 else { return nil }
    defer { Glibc.close(terminal) }
  #else
    return nil
  #endif

  return terminalWidth(fileDescriptor: terminal)
}

private func terminalWidth(fileDescriptor: Int32) -> Int? {
  #if canImport(Darwin)
    var size = Darwin.winsize()
    let result = Darwin.ioctl(fileDescriptor, TIOCGWINSZ, &size)
  #elseif canImport(Glibc)
    var size = Glibc.winsize()
    let result = Glibc.ioctl(fileDescriptor, UInt(TIOCGWINSZ), &size)
  #else
    return nil
  #endif

  guard result == 0, size.ws_col > 0 else { return nil }
  return Int(size.ws_col)
}
