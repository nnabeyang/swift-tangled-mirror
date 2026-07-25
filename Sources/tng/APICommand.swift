import ArgumentParser
import SwiftTangled

struct APIQueryField: ExpressibleByArgument, Equatable, Sendable {
  let name: String
  let value: String

  init?(argument: String) {
    guard let separator = argument.firstIndex(of: "="), separator != argument.startIndex else {
      return nil
    }
    self.name = String(argument[..<separator])
    self.value = String(argument[argument.index(after: separator)...])
  }
}

struct APICommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "api",
    abstract: "Call an allowlisted read-only Bobbin query"
  )

  @Argument(
    help: "Allowlisted Bobbin query NSID",
    completion: .list(BobbinClient.supportedRawQueryNSIDs)
  )
  var nsid: String

  @Option(
    name: [.customShort("f"), .long],
    parsing: .unconditionalSingleValue,
    help: "Query field in key=value form; repeat for arrays"
  )
  var field: [APIQueryField] = []

  @Flag(help: "Write response bytes without JSON formatting or a trailing newline")
  var raw = false

  func run() async throws {
    try await runCLICommand {
      try await APICommandService(formatter: .live).call(
        nsid: nsid,
        fields: field,
        raw: raw
      )
    }
  }
}
