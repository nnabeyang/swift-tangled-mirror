import Foundation
import SwiftAtproto

public struct PipelineLogControlStatus:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let start = PipelineLogControlStatus(rawValue: "start")
  public static let end = PipelineLogControlStatus(rawValue: "end")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct PipelineLogControlKind:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let system = PipelineLogControlKind(rawValue: "system")
  public static let user = PipelineLogControlKind(rawValue: "user")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct PipelineLogStream:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let stdout = PipelineLogStream(rawValue: "stdout")
  public static let stderr = PipelineLogStream(rawValue: "stderr")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct PipelineLogControl: Codable, Equatable, Hashable, Sendable {
  public let time: FormatString<Date>
  public let workflow: String
  public let step: Int
  public let content: String
  public let command: String?
  public let status: PipelineLogControlStatus?
  public let kind: PipelineLogControlKind?

  public init(
    time: FormatString<Date>,
    workflow: String,
    step: Int,
    content: String,
    command: String? = nil,
    status: PipelineLogControlStatus? = nil,
    kind: PipelineLogControlKind? = nil
  ) {
    self.time = time
    self.workflow = workflow
    self.step = step
    self.content = content
    self.command = command
    self.status = status
    self.kind = kind
  }
}

public struct PipelineLogData: Codable, Equatable, Hashable, Sendable {
  public let time: FormatString<Date>
  public let workflow: String
  public let step: Int
  public let content: String
  public let stream: PipelineLogStream

  public init(
    time: FormatString<Date>,
    workflow: String,
    step: Int,
    content: String,
    stream: PipelineLogStream
  ) {
    self.time = time
    self.workflow = workflow
    self.step = step
    self.content = content
    self.stream = stream
  }
}

public enum PipelineLogEvent: Codable, Equatable, Hashable, Sendable {
  case control(PipelineLogControl)
  case data(PipelineLogData)

  private enum CodingKeys: String, CodingKey {
    case type
  }

  private enum EventType: String, Codable {
    case control
    case data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(EventType.self, forKey: .type) {
    case .control:
      self = try .control(PipelineLogControl(from: decoder))
    case .data:
      self = try .data(PipelineLogData(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .control(let control):
      try container.encode(EventType.control, forKey: .type)
      try control.encode(to: encoder)
    case .data(let data):
      try container.encode(EventType.data, forKey: .type)
      try data.encode(to: encoder)
    }
  }
}
