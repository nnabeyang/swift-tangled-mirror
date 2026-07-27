import ArgumentParser
import Foundation
import SwiftTangled

struct CapabilitiesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capabilities",
    abstract: "Describe tng commands for tools and agents"
  )

  @Flag(help: "Output the versioned capability document as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      let document = try CapabilityCatalog.document()
      if json {
        return CLICommandOutput(stdout: try CLIFormatter.live.json(document))
      }
      return CLICommandOutput(
        stdout: CLIFormatter.live.table(
          headers: ["COMMAND", "ACCESS", "AUTH", "PLATFORMS"],
          rows: document.commands.map {
            [
              $0.path.joined(separator: " "),
              $0.access.rawValue,
              $0.authenticationRequired ? "required" : "not required",
              $0.platforms.joined(separator: ","),
            ]
          }
        )
      )
    }
  }
}

struct CapabilityDocument: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let cliVersion: String
  let commands: [CommandCapability]
}

struct CommandCapability: Codable, Equatable, Sendable {
  enum Access: String, Codable, Sendable {
    case read
    case write
  }

  let path: [String]
  let access: Access
  let authenticationRequired: Bool
  let platforms: [String]
  let arguments: [CapabilityArgument]
  let options: [CapabilityOption]
}

struct CapabilityArgument: Codable, Equatable, Sendable {
  let name: String
  let required: Bool
  let repeating: Bool
}

struct CapabilityOption: Codable, Equatable, Sendable {
  let names: [String]
  let valueName: String?
  let repeating: Bool
}

enum CapabilityCatalog {
  private struct Metadata {
    let access: CommandCapability.Access
    let authenticationRequired: Bool
  }

  private static let metadata: [String: Metadata] = [
    "auth login": Metadata(access: .write, authenticationRequired: false),
    "auth status": Metadata(access: .read, authenticationRequired: false),
    "auth logout": Metadata(access: .write, authenticationRequired: false),
    "repo list": Metadata(access: .read, authenticationRequired: false),
    "repo view": Metadata(access: .read, authenticationRequired: false),
    "repo tree": Metadata(access: .read, authenticationRequired: false),
    "repo log": Metadata(access: .read, authenticationRequired: false),
    "repo blob": Metadata(access: .read, authenticationRequired: false),
    "repo languages": Metadata(access: .read, authenticationRequired: false),
    "repo archive": Metadata(access: .write, authenticationRequired: false),
    "repo star": Metadata(access: .write, authenticationRequired: true),
    "repo unstar": Metadata(access: .write, authenticationRequired: true),
    "repo branch list": Metadata(access: .read, authenticationRequired: false),
    "repo tag list": Metadata(access: .read, authenticationRequired: false),
    "artifact list": Metadata(access: .read, authenticationRequired: false),
    "artifact view": Metadata(access: .read, authenticationRequired: false),
    "artifact upload": Metadata(access: .write, authenticationRequired: true),
    "artifact download": Metadata(access: .write, authenticationRequired: false),
    "artifact delete": Metadata(access: .write, authenticationRequired: true),
    "issue list": Metadata(access: .read, authenticationRequired: false),
    "issue view": Metadata(access: .read, authenticationRequired: false),
    "issue create": Metadata(access: .write, authenticationRequired: true),
    "issue comment": Metadata(access: .write, authenticationRequired: true),
    "issue edit": Metadata(access: .write, authenticationRequired: true),
    "issue close": Metadata(access: .write, authenticationRequired: true),
    "issue reopen": Metadata(access: .write, authenticationRequired: true),
    "pr list": Metadata(access: .read, authenticationRequired: false),
    "pr view": Metadata(access: .read, authenticationRequired: false),
    "pr diff": Metadata(access: .read, authenticationRequired: false),
    "pr create": Metadata(access: .write, authenticationRequired: true),
    "pr resubmit": Metadata(access: .write, authenticationRequired: true),
    "pr comment": Metadata(access: .write, authenticationRequired: true),
    "pr close": Metadata(access: .write, authenticationRequired: true),
    "pr reopen": Metadata(access: .write, authenticationRequired: true),
    "pr merge": Metadata(access: .write, authenticationRequired: true),
    "pipeline list": Metadata(access: .read, authenticationRequired: false),
    "pipeline view": Metadata(access: .read, authenticationRequired: false),
    "pipeline status": Metadata(access: .read, authenticationRequired: false),
    "pipeline watch": Metadata(access: .read, authenticationRequired: false),
    "events watch": Metadata(access: .read, authenticationRequired: false),
    "search": Metadata(access: .read, authenticationRequired: false),
    "api": Metadata(access: .read, authenticationRequired: false),
    "completion": Metadata(access: .read, authenticationRequired: false),
    "capabilities": Metadata(access: .read, authenticationRequired: false),
  ]

  static func document() throws -> CapabilityDocument {
    let data = Data(Tng._dumpHelp().utf8)
    let tool = try JSONDecoder().decode(ArgumentParserTool.self, from: data)
    let commands = try leafCommands(tool.command).map { command -> CommandCapability in
      let path = Array(command.superCommands.dropFirst()) + [command.commandName]
      let key = path.joined(separator: " ")
      guard let metadata = metadata[key] else {
        throw CapabilityCatalogError.missingMetadata(key)
      }
      let visible = command.arguments.filter {
        $0.shouldDisplay && !["help", "version"].contains($0.valueName)
      }
      return CommandCapability(
        path: path,
        access: metadata.access,
        authenticationRequired: metadata.authenticationRequired,
        platforms: ["linux", "macos"],
        arguments: visible.compactMap { argument in
          guard argument.kind == "positional" else { return nil }
          return CapabilityArgument(
            name: argument.valueName,
            required: !argument.isOptional,
            repeating: argument.isRepeating
          )
        },
        options: visible.compactMap { argument in
          guard argument.kind != "positional" else { return nil }
          return CapabilityOption(
            names: argument.names?.map(\.spelling) ?? [],
            valueName: argument.kind == "option" ? argument.valueName : nil,
            repeating: argument.isRepeating
          )
        }
      )
    }
    let sorted = commands.sorted {
      $0.path.joined(separator: " ") < $1.path.joined(separator: " ")
    }
    guard Set(sorted.map { $0.path.joined(separator: " ") }) == Set(metadata.keys) else {
      throw CapabilityCatalogError.commandTreeMismatch
    }
    return CapabilityDocument(
      schemaVersion: 1,
      cliVersion: SwiftTangled.version,
      commands: sorted
    )
  }

  private static func leafCommands(_ command: ArgumentParserCommand) -> [ArgumentParserCommand] {
    let children = (command.subcommands ?? []).filter { $0.commandName != "help" }
    guard !children.isEmpty else { return [command] }
    return children.flatMap(leafCommands)
  }
}

private enum CapabilityCatalogError: Error {
  case missingMetadata(String)
  case commandTreeMismatch
}

private struct ArgumentParserTool: Decodable {
  let command: ArgumentParserCommand
}

private struct ArgumentParserCommand: Decodable {
  let commandName: String
  let superCommands: [String]
  let subcommands: [ArgumentParserCommand]?
  let arguments: [ArgumentParserArgument]

  private enum CodingKeys: String, CodingKey {
    case commandName
    case superCommands
    case subcommands
    case arguments
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    commandName = try values.decode(String.self, forKey: .commandName)
    superCommands = try values.decodeIfPresent([String].self, forKey: .superCommands) ?? []
    subcommands = try values.decodeIfPresent([ArgumentParserCommand].self, forKey: .subcommands)
    arguments = try values.decodeIfPresent([ArgumentParserArgument].self, forKey: .arguments) ?? []
  }
}

private struct ArgumentParserArgument: Decodable {
  let kind: String
  let names: [ArgumentParserName]?
  let valueName: String
  let isOptional: Bool
  let isRepeating: Bool
  let shouldDisplay: Bool
}

private struct ArgumentParserName: Decodable {
  let kind: String
  let name: String

  var spelling: String {
    switch kind {
    case "short", "longWithSingleDash": "-\(name)"
    default: "--\(name)"
    }
  }
}
