import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct CLITextFileReaderTests {
  @Test func readsUTF8FromFileAndStandardInput() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("tng-body-\(UUID().uuidString).md")
    try Data("From file\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let reader = CLITextFileReader(
      readStandardInput: { Data("From stdin\n".utf8) }
    )

    #expect(try reader.read(path: file.path) == "From file\n")
    #expect(try reader.read(path: "-") == "From stdin\n")
  }

  @Test func rejectsUnreadableAndInvalidUTF8Input() {
    let invalid = CLITextFileReader(readStandardInput: { Data([0xff]) })

    #expect(throws: TangledError.self) {
      _ = try CLITextFileReader().read(path: "/does/not/exist")
    }
    #expect(throws: TangledError.self) {
      _ = try invalid.read(path: "-")
    }
  }
}
