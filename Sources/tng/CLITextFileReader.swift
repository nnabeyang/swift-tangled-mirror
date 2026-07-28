import Foundation
import SwiftTangled

struct CLITextFileReader: Sendable {
  private let readStandardInput: @Sendable () throws -> Data

  init(
    readStandardInput: @escaping @Sendable () throws -> Data = {
      try FileHandle.standardInput.readToEnd() ?? Data()
    }
  ) {
    self.readStandardInput = readStandardInput
  }

  func read(path: String) throws -> String {
    let data: Data
    do {
      data =
        if path == "-" {
          try readStandardInput()
        } else {
          try Data(contentsOf: URL(fileURLWithPath: path))
        }
    } catch {
      throw TangledError.invalidRequest("unable to read body file: \(path)")
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw TangledError.invalidRequest("body file must contain valid UTF-8: \(path)")
    }
    return value
  }
}
