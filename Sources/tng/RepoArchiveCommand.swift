import ArgumentParser
import SwiftTangled

enum RepoArchiveFormat: String, CaseIterable, ExpressibleByArgument {
  case tarGzip = "tar.gz"
  case zip

  var gitArchiveFormat: GitArchiveFormat {
    switch self {
    case .tarGzip:
      return .tarGzip
    case .zip:
      return .zip
    }
  }
}

struct RepoArchiveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "archive",
    abstract: "Download a repository archive"
  )

  @Argument(help: "Repository DID, AT URI, handle/name, or clone URL")
  var repository: String?

  @Option(help: "Git reference to archive (defaults to the default branch)")
  var ref: String?

  @Option(help: "Archive format: tar.gz or zip")
  var format: RepoArchiveFormat = .tarGzip

  @Option(help: "Prefix to add to every path in the archive")
  var prefix: String?

  @Option(name: [.customShort("o"), .long], help: "Path to save the archive")
  var output: String

  @Flag(help: "Replace an existing output file")
  var force = false

  func run() async throws {
    try await runCLICommand {
      try await RepoCommandService(formatter: .live).archive(
        repository: repository,
        ref: ref,
        format: format.gitArchiveFormat,
        prefix: prefix,
        output: output,
        force: force
      )
    }
  }
}
