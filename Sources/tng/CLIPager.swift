import Foundation
import Subprocess

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
    ) async throws -> Void

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
  ) async throws {
    ignoreBrokenPipeSignal()

    let result: ExecutionResult<PagerRun, FileDescriptorOutput, FileDescriptorOutput>
    do {
      result = try await Subprocess.run(
        CLISubprocess.executable("/bin/sh"),
        arguments: ["-c", command],
        environment: .custom(pagerEnvironmentKeys(environment)),
        platformOptions: CLISubprocess.platformOptions,
        input: .inputWriter,
        output: .currentStandardOutput,
        error: .currentStandardError
      ) { execution in
        let foreground = PagerTerminalForeground(
          pagerProcessID: execution.processIdentifier.value
        )
        do {
          _ = try await execution.standardInputWriter.write(data)
        } catch {
          guard isBrokenPipe(error) else {
            return PagerRun(foreground: foreground, writeFailure: "\(error)")
          }
        }
        return PagerRun(foreground: foreground, writeFailure: nil)
      }
    } catch {
      throw CLIPagerError.launch(command: command, message: "\(error)")
    }

    result.closureResult.foreground.restore()

    if let writeFailure = result.closureResult.writeFailure {
      throw CLIPagerError.write(command: command, message: writeFailure)
    }
    switch result.terminationStatus {
    case .exited(let status) where status != 0:
      throw CLIPagerError.exit(command: command, status: status)
    case .signaled(let signal):
      throw CLIPagerError.signal(command: command, signal: signal)
    default:
      return
    }
  }
}

struct CLIOutputWriter {
  let terminal: CLITerminalContext
  let diagnosticFormatter: CLIDiagnosticFormatter
  let environment: [String: String]
  let pager: CLIPager
  let stdout: (Data) -> Void
  let stderr: (Data) -> Void

  init(
    terminal: CLITerminalContext,
    diagnosticFormatter: CLIDiagnosticFormatter = .plain,
    environment: [String: String],
    pager: CLIPager,
    stdout: @escaping (Data) -> Void,
    stderr: @escaping (Data) -> Void
  ) {
    self.terminal = terminal
    self.diagnosticFormatter = diagnosticFormatter
    self.environment = environment
    self.pager = pager
    self.stdout = stdout
    self.stderr = stderr
  }

  static var live: CLIOutputWriter {
    CLIOutputWriter(
      terminal: .live,
      diagnosticFormatter: .live,
      environment: ProcessInfo.processInfo.environment,
      pager: .live,
      stdout: { FileHandle.standardOutput.write($0) },
      stderr: { FileHandle.standardError.write($0) }
    )
  }

  func write(_ output: CLICommandOutput) async {
    var pagerWarning: String?
    if output.isPageable,
      terminal.isTerminal,
      let command = CLIPager.command(environment: environment),
      command != "cat"
    {
      do {
        try await pager.run(
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
      stderr(Data(diagnosticFormatter.format(output.stderr).utf8))
    }
    if let pagerWarning {
      stderr(Data(diagnosticFormatter.format(pagerWarning).utf8))
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
  (error as? SubprocessError)?.underlyingError == .brokenPipe
}

private func pagerEnvironmentKeys(_ environment: [String: String]) -> [Environment.Key: String] {
  Dictionary(
    uniqueKeysWithValues: environment.compactMap { key, value in
      Environment.Key(rawValue: key).map { ($0, value) }
    }
  )
}

private struct PagerRun: Sendable {
  let foreground: PagerTerminalForeground
  let writeFailure: String?
}

private struct PagerTerminalForeground: Sendable {
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
