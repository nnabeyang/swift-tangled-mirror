import ArgumentParser
import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct CapabilitiesCommandTests {
  @Test func parsesHumanAndJSONOutputModes() throws {
    let human = try CapabilitiesCommand.parse([])
    let json = try CapabilitiesCommand.parse(["--json"])

    #expect(!human.json)
    #expect(json.json)
  }

  @Test func documentDescribesEveryLeafCommandAndStableSchema() throws {
    let document = try CapabilityCatalog.document()
    let paths = Set(document.commands.map { $0.path.joined(separator: " ") })

    #expect(document.schemaVersion == 1)
    #expect(document.cliVersion == SwiftTangled.version)
    #expect(paths.count == 46)
    #expect(paths.contains("capabilities"))
    #expect(paths.contains("pr create"))
    #expect(paths.contains("pr edit"))
    #expect(paths.contains("pr resubmit"))
    #expect(paths.contains("pr close"))
    #expect(paths.contains("pr reopen"))
    #expect(paths.contains("issue create"))
    #expect(paths.contains("issue comment"))
    #expect(paths.contains("issue edit"))
    #expect(paths.contains("issue close"))
    #expect(paths.contains("issue reopen"))
    #expect(paths.contains("pipeline watch"))
    #expect(paths.contains("pipeline retry"))
    #expect(paths.contains("events watch"))
    #expect(paths.contains("artifact list"))
    #expect(paths.contains("artifact view"))
    #expect(paths.contains("artifact upload"))
    #expect(paths.contains("artifact download"))
    #expect(paths.contains("artifact delete"))
    #expect(!paths.contains("help"))
  }

  @Test func documentIncludesArgumentsOptionsAndSafetyMetadata() throws {
    let document = try CapabilityCatalog.document()
    let pullCreate = try #require(
      document.commands.first { $0.path == ["pr", "create"] }
    )
    let pullClose = try #require(
      document.commands.first { $0.path == ["pr", "close"] }
    )
    let pullEdit = try #require(
      document.commands.first { $0.path == ["pr", "edit"] }
    )
    let pullResubmit = try #require(
      document.commands.first { $0.path == ["pr", "resubmit"] }
    )
    let repoArchive = try #require(
      document.commands.first { $0.path == ["repo", "archive"] }
    )
    let repoList = try #require(
      document.commands.first { $0.path == ["repo", "list"] }
    )
    let issueCreate = try #require(
      document.commands.first { $0.path == ["issue", "create"] }
    )
    let issueComment = try #require(
      document.commands.first { $0.path == ["issue", "comment"] }
    )
    let issueEdit = try #require(
      document.commands.first { $0.path == ["issue", "edit"] }
    )
    let artifactUpload = try #require(
      document.commands.first { $0.path == ["artifact", "upload"] }
    )
    let artifactDownload = try #require(
      document.commands.first { $0.path == ["artifact", "download"] }
    )
    let pipelineReads = document.commands.filter {
      [
        ["pipeline", "list"],
        ["pipeline", "view"],
        ["pipeline", "status"],
      ].contains($0.path)
    }
    let pipelineRetry = try #require(
      document.commands.first { $0.path == ["pipeline", "retry"] }
    )

    #expect(pullCreate.access == .write)
    #expect(pullCreate.authenticationRequired)
    #expect(pullCreate.options.contains { $0.names.contains("--body-file") })
    #expect(pullEdit.access == .write)
    #expect(pullEdit.authenticationRequired)
    #expect(pullEdit.options.contains { $0.names == ["-t", "--title"] })
    #expect(pullEdit.options.contains { $0.names == ["-b", "--body"] })
    #expect(pullEdit.options.contains { $0.names == ["-F", "--body-file"] })
    #expect(pullClose.access == .write)
    #expect(pullClose.authenticationRequired)
    #expect(
      pullClose.arguments == [
        CapabilityArgument(name: "pull-request-uri", required: true, repeating: false)
      ])
    #expect(pullResubmit.access == .write)
    #expect(pullResubmit.authenticationRequired)
    #expect(
      pullResubmit.arguments == [
        CapabilityArgument(name: "pull-request-uri", required: true, repeating: false)
      ])
    #expect(repoArchive.access == .write)
    #expect(!repoArchive.authenticationRequired)
    #expect(repoList.access == .read)
    #expect(repoList.platforms == ["linux", "macos"])
    #expect(
      repoList.arguments == [
        CapabilityArgument(name: "owner", required: false, repeating: false)
      ]
    )
    #expect(repoList.options.contains { $0.names == ["-L", "--limit"] })
    #expect(issueCreate.access == .write)
    #expect(issueCreate.authenticationRequired)
    #expect(issueCreate.options.contains { $0.names.contains("--body-file") })
    #expect(issueComment.access == .write)
    #expect(issueComment.authenticationRequired)
    #expect(issueComment.options.contains { $0.names.contains("--body-file") })
    #expect(issueEdit.access == .write)
    #expect(issueEdit.authenticationRequired)
    #expect(issueEdit.options.contains { $0.names.contains("--body-file") })
    #expect(artifactUpload.access == .write)
    #expect(artifactUpload.authenticationRequired)
    #expect(artifactUpload.options.contains { $0.names.contains("--content-type") })
    #expect(artifactDownload.access == .write)
    #expect(!artifactDownload.authenticationRequired)
    #expect(artifactDownload.options.contains { $0.names == ["-o", "--output"] })
    #expect(pipelineReads.count == 3)
    #expect(
      pipelineReads.allSatisfy { command in
        command.options.contains { $0.names == ["--spindle"] }
      }
    )
    #expect(pipelineRetry.access == .write)
    #expect(pipelineRetry.authenticationRequired)
    #expect(pipelineRetry.options.contains { $0.names == ["--workflow"] })
  }

  @Test func capabilityJSONRoundTrips() throws {
    let document = try CapabilityCatalog.document()
    let output = try CLIFormatter.plain.json(document)
    let decoded = try JSONDecoder().decode(CapabilityDocument.self, from: Data(output.utf8))

    #expect(decoded == document)
  }
}
