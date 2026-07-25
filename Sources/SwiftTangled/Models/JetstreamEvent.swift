import Foundation

public struct JetstreamEventKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let commit = JetstreamEventKind(rawValue: "commit")
  public static let identity = JetstreamEventKind(rawValue: "identity")
  public static let account = JetstreamEventKind(rawValue: "account")
}

public struct JetstreamCommitOperation: RawRepresentable, Codable, Equatable, Hashable,
  Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let create = JetstreamCommitOperation(rawValue: "create")
  public static let update = JetstreamCommitOperation(rawValue: "update")
  public static let delete = JetstreamCommitOperation(rawValue: "delete")
}

public struct JetstreamCommit: Codable, Equatable, Hashable, Sendable {
  public let rev: String
  public let operation: JetstreamCommitOperation
  public let collection: String
  public let rkey: String
  public let record: JSONValue?
  public let cid: String?

  public init(
    rev: String,
    operation: JetstreamCommitOperation,
    collection: String,
    rkey: String,
    record: JSONValue? = nil,
    cid: String? = nil
  ) {
    self.rev = rev
    self.operation = operation
    self.collection = collection
    self.rkey = rkey
    self.record = record
    self.cid = cid
  }
}

public struct JetstreamIdentity: Codable, Equatable, Hashable, Sendable {
  public let did: String
  public let handle: String?
  public let seq: Int64
  public let time: String

  public init(did: String, handle: String?, seq: Int64, time: String) {
    self.did = did
    self.handle = handle
    self.seq = seq
    self.time = time
  }
}

public struct JetstreamAccount: Codable, Equatable, Hashable, Sendable {
  public let active: Bool
  public let did: String
  public let seq: Int64
  public let time: String
  public let status: String?

  public init(active: Bool, did: String, seq: Int64, time: String, status: String? = nil) {
    self.active = active
    self.did = did
    self.seq = seq
    self.time = time
    self.status = status
  }
}

public struct TangledEvent: Codable, Equatable, Hashable, Sendable {
  public let did: String
  public let timeUS: Int64
  public let kind: JetstreamEventKind
  public let commit: JetstreamCommit?
  public let identity: JetstreamIdentity?
  public let account: JetstreamAccount?

  public init(
    did: String,
    timeUS: Int64,
    kind: JetstreamEventKind,
    commit: JetstreamCommit? = nil,
    identity: JetstreamIdentity? = nil,
    account: JetstreamAccount? = nil
  ) {
    self.did = did
    self.timeUS = timeUS
    self.kind = kind
    self.commit = commit
    self.identity = identity
    self.account = account
  }

  enum CodingKeys: String, CodingKey {
    case did
    case timeUS = "time_us"
    case kind
    case commit
    case identity
    case account
  }
}
