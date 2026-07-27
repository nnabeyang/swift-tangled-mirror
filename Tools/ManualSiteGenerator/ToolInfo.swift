import Foundation

struct ToolInfo: Decodable, Sendable {
  let serializationVersion: Int
  let command: CommandInfo

  func validate() throws {
    guard serializationVersion == 0 else {
      throw ManualSiteError.unsupportedSerializationVersion(serializationVersion)
    }
  }
}

struct CommandInfo: Decodable, Sendable {
  let commandName: String
  let abstract: String?
  let discussion: String?
  let shouldDisplay: Bool
  let subcommands: [CommandInfo]
  let arguments: [ArgumentInfo]

  private enum CodingKeys: String, CodingKey {
    case commandName
    case abstract
    case discussion
    case shouldDisplay
    case subcommands
    case arguments
  }

  init(
    commandName: String,
    abstract: String? = nil,
    discussion: String? = nil,
    shouldDisplay: Bool = true,
    subcommands: [CommandInfo] = [],
    arguments: [ArgumentInfo] = []
  ) {
    self.commandName = commandName
    self.abstract = abstract
    self.discussion = discussion
    self.shouldDisplay = shouldDisplay
    self.subcommands = subcommands
    self.arguments = arguments
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    commandName = try values.decode(String.self, forKey: .commandName)
    abstract = try values.decodeIfPresent(String.self, forKey: .abstract)
    discussion = try values.decodeIfPresent(String.self, forKey: .discussion)
    shouldDisplay = try values.decodeIfPresent(Bool.self, forKey: .shouldDisplay) ?? true
    subcommands = try values.decodeIfPresent([CommandInfo].self, forKey: .subcommands) ?? []
    arguments = try values.decodeIfPresent([ArgumentInfo].self, forKey: .arguments) ?? []
  }
}

struct ArgumentInfo: Decodable, Sendable {
  let abstract: String?
  let discussion: String?
  let defaultValue: String?
  let allValues: [String]?
  let isOptional: Bool
  let isRepeating: Bool
  let kind: String
  let names: [ArgumentName]
  let preferredName: ArgumentName?
  let shouldDisplay: Bool
  let valueName: String

  private enum CodingKeys: String, CodingKey {
    case abstract
    case discussion
    case defaultValue
    case allValues
    case isOptional
    case isRepeating
    case kind
    case names
    case preferredName
    case shouldDisplay
    case valueName
  }

  init(
    abstract: String? = nil,
    discussion: String? = nil,
    defaultValue: String? = nil,
    allValues: [String]? = nil,
    isOptional: Bool,
    isRepeating: Bool = false,
    kind: String,
    names: [ArgumentName] = [],
    preferredName: ArgumentName? = nil,
    shouldDisplay: Bool = true,
    valueName: String
  ) {
    self.abstract = abstract
    self.discussion = discussion
    self.defaultValue = defaultValue
    self.allValues = allValues
    self.isOptional = isOptional
    self.isRepeating = isRepeating
    self.kind = kind
    self.names = names
    self.preferredName = preferredName
    self.shouldDisplay = shouldDisplay
    self.valueName = valueName
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    abstract = try values.decodeIfPresent(String.self, forKey: .abstract)
    discussion = try values.decodeIfPresent(String.self, forKey: .discussion)
    defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue)
    allValues = try values.decodeIfPresent([String].self, forKey: .allValues)
    isOptional = try values.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
    isRepeating = try values.decodeIfPresent(Bool.self, forKey: .isRepeating) ?? false
    kind = try values.decode(String.self, forKey: .kind)
    names = try values.decodeIfPresent([ArgumentName].self, forKey: .names) ?? []
    preferredName = try values.decodeIfPresent(ArgumentName.self, forKey: .preferredName)
    shouldDisplay = try values.decodeIfPresent(Bool.self, forKey: .shouldDisplay) ?? true
    valueName = try values.decodeIfPresent(String.self, forKey: .valueName) ?? ""
  }
}

struct ArgumentName: Codable, Equatable, Sendable {
  let kind: String
  let name: String

  var spelling: String {
    switch kind {
    case "short", "longWithSingleDash":
      return "-\(name)"
    default:
      return "--\(name)"
    }
  }
}
