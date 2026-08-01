import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct CLISecretReader: Sendable {
  private let inputIsTerminal: @Sendable () -> Bool
  private let readHiddenLine: @Sendable () throws -> String
  private let readStandardInput: @Sendable () throws -> Data

  init(
    inputIsTerminal: @escaping @Sendable () -> Bool = { secretStandardInputIsTerminal() },
    readHiddenLine: @escaping @Sendable () throws -> String = { try readHiddenSecretLine() },
    readStandardInput: @escaping @Sendable () throws -> Data = {
      try FileHandle.standardInput.readToEnd() ?? Data()
    }
  ) {
    self.inputIsTerminal = inputIsTerminal
    self.readHiddenLine = readHiddenLine
    self.readStandardInput = readStandardInput
  }

  func read() throws -> String {
    if inputIsTerminal() {
      return try readHiddenLine()
    }
    let data: Data
    do {
      data = try readStandardInput()
    } catch {
      throw TangledError.invalidRequest("unable to read the secret value from standard input")
    }
    var valueData = data
    if valueData.suffix(2).elementsEqual([13, 10]) {
      valueData.removeLast(2)
    } else if valueData.last == 10 {
      valueData.removeLast()
    }
    guard let value = String(data: valueData, encoding: .utf8) else {
      throw TangledError.invalidRequest("the secret value must be valid UTF-8")
    }
    return value
  }
}

private func secretStandardInputIsTerminal() -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #else
    false
  #endif
}

private func readHiddenSecretLine() throws -> String {
  let descriptor = FileHandle.standardInput.fileDescriptor
  var original = termios()
  guard tcgetattr(descriptor, &original) == 0 else {
    throw TangledError.invalidRequest("unable to configure hidden secret input")
  }
  var hidden = original
  hidden.c_lflag &= ~tcflag_t(ECHO)
  guard tcsetattr(descriptor, TCSANOW, &hidden) == 0 else {
    throw TangledError.invalidRequest("unable to configure hidden secret input")
  }
  FileHandle.standardError.write(Data("Secret value: ".utf8))
  defer {
    var restored = original
    _ = tcsetattr(descriptor, TCSANOW, &restored)
    FileHandle.standardError.write(Data("\n".utf8))
  }
  guard let value = readLine() else {
    throw TangledError.invalidRequest("unable to read the secret value")
  }
  return value
}
