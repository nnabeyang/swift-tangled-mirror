import Foundation
import SwiftTangled

struct APICommandDependencies: Sendable {
  let query: @Sendable (String, [URLQueryItem], Bool) async throws -> Data

  static let live = APICommandDependencies(
    query: { nsid, queryItems, allowsRawResponse in
      try await BobbinClient().rawQuery(
        nsid: nsid,
        queryItems: queryItems,
        allowsRawResponse: allowsRawResponse
      )
    }
  )
}

struct APICommandService: Sendable {
  private let dependencies: APICommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: APICommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func call(
    nsid: String,
    fields: [APIQueryField],
    raw: Bool
  ) async throws -> CLICommandOutput {
    let data = try await dependencies.query(
      nsid,
      fields.map { URLQueryItem(name: $0.name, value: $0.value) },
      raw
    )
    guard !raw else {
      return CLICommandOutput(stdoutData: data)
    }
    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      return CLICommandOutput(stdout: try formatter.json(value))
    } catch let error as TangledError {
      throw error
    } catch {
      throw TangledError.decoding(error)
    }
  }
}
