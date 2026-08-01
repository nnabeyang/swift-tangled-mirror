import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct CLISecretReaderTests {
  @Test func readsHiddenTerminalInputWithoutReadingStandardInput() throws {
    let reader = CLISecretReader(
      inputIsTerminal: { true },
      readHiddenLine: { "hidden-value" },
      readStandardInput: {
        Issue.record("standard input must not be read for a terminal")
        return Data()
      }
    )

    #expect(try reader.read().utf8.count == 12)
  }

  @Test func removesExactlyOnePipedLineEndingAndPreservesOtherWhitespace() throws {
    let unix = CLISecretReader(
      inputIsTerminal: { false },
      readStandardInput: { Data(" value \n\n".utf8) }
    )
    let windows = CLISecretReader(
      inputIsTerminal: { false },
      readStandardInput: { Data("value\r\n".utf8) }
    )

    #expect(try unix.read() == " value \n")
    #expect(try windows.read() == "value")
  }

  @Test func reportsInvalidInputWithoutIncludingItsBytes() {
    let reader = CLISecretReader(
      inputIsTerminal: { false },
      readStandardInput: { Data([0xff, 0xfe]) }
    )

    #expect(throws: TangledError.self) {
      _ = try reader.read()
    }
  }
}
