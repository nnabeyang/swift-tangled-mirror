import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct APICommandTests {
  @Test func parsesFieldsAndRawFlag() throws {
    let command = try APICommand.parse([
      "sh.tangled.actor.getProfile",
      "-f", "did=did:plc:alice",
      "--field", "tag=one=two",
      "-f", "empty=",
      "--raw",
    ])

    #expect(command.nsid == "sh.tangled.actor.getProfile")
    #expect(
      command.field
        == [
          APIQueryField(argument: "did=did:plc:alice"),
          APIQueryField(argument: "tag=one=two"),
          APIQueryField(argument: "empty="),
        ].compactMap { $0 }
    )
    #expect(command.raw)
    #expect(throws: (any Error).self) {
      _ = try APICommand.parse(["sh.tangled.actor.getProfile", "-f", "missing-separator"])
    }
    #expect(throws: (any Error).self) {
      _ = try APICommand.parse(["sh.tangled.actor.getProfile", "-f", "=missing-key"])
    }
  }

  @Test func formatsArbitraryJSONAndPassesFieldsInOrder() async throws {
    let recorder = APICommandRecorder(response: Data(#"{"z":1,"a":{"ok":true}}"#.utf8))
    let service = APICommandService(dependencies: dependencies(recorder: recorder))
    let fields = [
      APIQueryField(argument: "did=did:plc:alice")!,
      APIQueryField(argument: "did=did:plc:bob")!,
    ]

    let output = try await service.call(
      nsid: "sh.tangled.actor.getProfile",
      fields: fields,
      raw: false
    )

    #expect(output.stdout == "{\n  \"a\" : {\n    \"ok\" : true\n  },\n  \"z\" : 1\n}\n")
    #expect(output.stderr.isEmpty)
    #expect(
      await recorder.calls()
        == [
          APICall(
            nsid: "sh.tangled.actor.getProfile",
            queryItems: [
              URLQueryItem(name: "did", value: "did:plc:alice"),
              URLQueryItem(name: "did", value: "did:plc:bob"),
            ],
            allowsRawResponse: false
          )
        ]
    )
  }

  @Test func rawOutputPreservesEveryByte() async throws {
    let data = Data([0x00, 0xFF, 0x0A, 0x41])
    let recorder = APICommandRecorder(response: data)
    let service = APICommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.call(
      nsid: "sh.tangled.repo.archive",
      fields: [],
      raw: true
    )

    #expect(output.stdoutData == data)
    #expect(output.stderr.isEmpty)
    #expect(await recorder.calls().first?.allowsRawResponse == true)
  }

  @Test func invalidJSONMapsToTangledDecodingError() async {
    let recorder = APICommandRecorder(response: Data("not-json".utf8))
    let service = APICommandService(dependencies: dependencies(recorder: recorder))

    await #expect(throws: TangledError.self) {
      _ = try await service.call(
        nsid: "sh.tangled.actor.getProfile",
        fields: [],
        raw: false
      )
    }
  }
}

extension APICommandTests {
  fileprivate func dependencies(recorder: APICommandRecorder) -> APICommandDependencies {
    APICommandDependencies(
      query: { nsid, queryItems, allowsRawResponse in
        await recorder.record(
          APICall(
            nsid: nsid,
            queryItems: queryItems,
            allowsRawResponse: allowsRawResponse
          )
        )
        return recorder.response
      }
    )
  }
}

private struct APICall: Equatable, Sendable {
  let nsid: String
  let queryItems: [URLQueryItem]
  let allowsRawResponse: Bool
}

private actor APICommandRecorder {
  let response: Data
  private var recordedCalls: [APICall] = []

  init(response: Data) {
    self.response = response
  }

  func record(_ call: APICall) {
    recordedCalls.append(call)
  }

  func calls() -> [APICall] {
    recordedCalls
  }
}
