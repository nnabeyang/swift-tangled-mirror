import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum CLIPagerError: Error, Equatable, Sendable, CustomStringConvertible {
  case launch(command: String, message: String)
  case write(command: String, message: String)
  case exit(command: String, status: Int32)
  case signal(command: String, signal: Int32)

  var description: String {
    switch self {
    case .launch(let command, let message):
      "unable to start '\(command)': \(message)"
    case .write(let command, let message):
      "unable to write to '\(command)': \(message)"
    case .exit(let command, let status):
      "'\(command)' exited with status \(status)"
    case .signal(let command, let signal):
      "'\(command)' terminated by signal \(signal)"
    }
  }

  var shouldWriteDirectly: Bool {
    switch self {
    case .launch:
      true
    case .exit(_, let status):
      status == 127
    case .write, .signal:
      false
    }
  }

  var warning: String {
    if shouldWriteDirectly {
      return "warning: pager unavailable: \(description); writing output directly\n"
    }
    return "warning: pager failed: \(description); output may be incomplete\n"
  }
}

struct CLIPager: Sendable {
  typealias Runner =
    @Sendable (
      _ command: String,
      _ data: Data,
      _ environment: [String: String]
    ) throws -> Void

  let run: Runner

  static let live = CLIPager(run: runProcess)

  static func command(environment: [String: String]) -> String? {
    for name in ["TNG_PAGER", "PAGER"] {
      guard let value = environment[name] else { continue }
      return value.isEmpty ? nil : value
    }
    return environment["TERM"] == "dumb" ? nil : "less"
  }

  static func pagerEnvironment(_ environment: [String: String]) -> [String: String] {
    var environment = environment
    if environment["LESS"] == nil {
      environment["LESS"] = "FRX"
    }
    if environment["LV"] == nil {
      environment["LV"] = "-c"
    }
    return environment
  }

  static func runProcess(
    command: String,
    data: Data,
    environment: [String: String]
  ) throws {
    let process = Process()
    let standardInput = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = environment
    process.standardInput = standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    do {
      try process.run()
    } catch {
      throw CLIPagerError.launch(command: command, message: error.localizedDescription)
    }

    let terminalForeground = PagerTerminalForeground(
      pagerProcessID: process.processIdentifier
    )
    ignoreBrokenPipeSignal()
    var writeError: (any Error)?
    do {
      try standardInput.fileHandleForWriting.write(contentsOf: data)
    } catch {
      if !isBrokenPipe(error) {
        writeError = error
      }
    }
    try? standardInput.fileHandleForWriting.close()
    process.waitUntilExit()
    terminalForeground.restore()

    if let writeError {
      throw CLIPagerError.write(
        command: command,
        message: writeError.localizedDescription
      )
    }
    switch process.terminationReason {
    case .exit where process.terminationStatus != 0:
      throw CLIPagerError.exit(command: command, status: process.terminationStatus)
    case .uncaughtSignal:
      throw CLIPagerError.signal(command: command, signal: process.terminationStatus)
    default:
      return
    }
  }
}

struct CLIOutputWriter {
  let terminal: CLITerminalContext
  let environment: [String: String]
  let pager: CLIPager
  let stdout: (Data) -> Void
  let stderr: (Data) -> Void

  static var live: CLIOutputWriter {
    CLIOutputWriter(
      terminal: .live,
      environment: ProcessInfo.processInfo.environment,
      pager: .live,
      stdout: { FileHandle.standardOutput.write($0) },
      stderr: { FileHandle.standardError.write($0) }
    )
  }

  func write(_ output: CLICommandOutput) {
    var pagerWarning: String?
    if output.isPageable,
      terminal.isTerminal,
      let command = CLIPager.command(environment: environment),
      command != "cat"
    {
      do {
        try pager.run(
          command,
          output.stdoutData,
          CLIPager.pagerEnvironment(environment)
        )
      } catch let error as CLIPagerError {
        if error.shouldWriteDirectly, !output.stdoutData.isEmpty {
          stdout(output.stdoutData)
        }
        pagerWarning = error.warning
      } catch {
        if !output.stdoutData.isEmpty {
          stdout(output.stdoutData)
        }
        pagerWarning =
          "warning: pager unavailable: \(error); writing output directly\n"
      }
    } else if !output.stdoutData.isEmpty {
      stdout(output.stdoutData)
    }

    if !output.stderr.isEmpty {
      stderr(Data(output.stderr.utf8))
    }
    if let pagerWarning {
      stderr(Data(pagerWarning.utf8))
    }
  }
}

private func ignoreBrokenPipeSignal() {
  #if canImport(Darwin)
    Darwin.signal(SIGPIPE, SIG_IGN)
  #elseif canImport(Glibc)
    Glibc.signal(SIGPIPE, SIG_IGN)
  #endif
}

private func isBrokenPipe(_ error: any Error) -> Bool {
  let error = error as NSError
  if error.domain == NSPOSIXErrorDomain, error.code == Int(EPIPE) {
    return true
  }
  if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
    return isBrokenPipe(underlying)
  }
  return false
}

private struct PagerTerminalForeground {
  private let terminal: Int32?
  private let originalProcessGroup: pid_t

  init(pagerProcessID: pid_t) {
    originalProcessGroup = systemGetProcessGroup()
    let terminal = FileHandle.standardOutput.fileDescriptor
    guard systemIsTerminal(terminal), systemSetForegroundProcessGroup(terminal, pagerProcessID) else {
      self.terminal = nil
      return
    }

    self.terminal = terminal
    systemContinueProcessGroup(pagerProcessID)
  }

  func restore() {
    guard let terminal else { return }
    _ = systemSetForegroundProcessGroup(terminal, originalProcessGroup)
  }
}

private func systemGetProcessGroup() -> pid_t {
  #if canImport(Darwin)
    Darwin.getpgrp()
  #elseif canImport(Glibc)
    Glibc.getpgrp()
  #else
    0
  #endif
}

private func systemIsTerminal(_ fileDescriptor: Int32) -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(fileDescriptor) == 1
  #else
    false
  #endif
}

private func systemSetForegroundProcessGroup(
  _ fileDescriptor: Int32,
  _ processGroup: pid_t
) -> Bool {
  #if canImport(Darwin)
    Darwin.signal(SIGTTOU, SIG_IGN)
    return Darwin.tcsetpgrp(fileDescriptor, processGroup) == 0
  #elseif canImport(Glibc)
    Glibc.signal(SIGTTOU, SIG_IGN)
    return Glibc.tcsetpgrp(fileDescriptor, processGroup) == 0
  #else
    return false
  #endif
}

private func systemContinueProcessGroup(_ processGroup: pid_t) {
  #if canImport(Darwin)
    _ = Darwin.kill(-processGroup, SIGCONT)
  #elseif canImport(Glibc)
    _ = Glibc.kill(-processGroup, SIGCONT)
  #endif
}
