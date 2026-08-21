import Foundation
import Subprocess
import Testing

@testable import tng

@Suite struct CLISubprocessTests {
  @Test func spawnedChildLeadsItsOwnProcessGroup() async throws {
    let result = try await Subprocess.run(
      CLISubprocess.executable("/bin/sh"),
      arguments: ["-c", "printf '%s %s' \"$$\" \"$(ps -o pgid= -p $$)\""],
      platformOptions: CLISubprocess.platformOptions,
      output: .string(limit: CLISubprocess.textOutputLimit)
    )

    let fields = result.standardOutput.split(whereSeparator: \.isWhitespace)
    #expect(fields.count == 2)
    #expect(fields.first == fields.last)
  }

  @Test func statusReportsExitCodesAndSignals() {
    #expect(CLISubprocess.status(.exited(7)) == 7)
    #expect(CLISubprocess.status(.signaled(SIGTERM)) == SIGTERM)
  }
}
