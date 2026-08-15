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
    #expect(paths.count == 71)
    #expect(paths.contains("capabilities"))
    #expect(paths.contains("auth agent serve"))
    #expect(paths.contains("auth agent service install"))
    #expect(paths.contains("auth agent service start"))
    #expect(paths.contains("auth agent service status"))
    #expect(paths.contains("auth agent service restart"))
    #expect(paths.contains("auth agent service stop"))
    #expect(paths.contains("auth agent service uninstall"))
    #expect(paths.contains("auth agent tmb enroll"))
    #expect(paths.contains("auth agent tmb login"))
    #expect(paths.contains("auth agent tmb verify"))
    #expect(paths.contains("auth agent tmb logout"))
    #expect(paths.contains("auth agent tmb status"))
    #expect(paths.contains("auth agent tmb revoke"))
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
    #expect(paths.contains("pipeline logs"))
    #expect(paths.contains("pipeline retry"))
    #expect(paths.contains("pipeline run"))
    #expect(paths.contains("pipeline cancel"))
    #expect(paths.contains("events watch"))
    #expect(paths.contains("artifact list"))
    #expect(paths.contains("artifact view"))
    #expect(paths.contains("artifact upload"))
    #expect(paths.contains("artifact download"))
    #expect(paths.contains("artifact delete"))
    #expect(paths.contains("repo create"))
    #expect(paths.contains("repo delete"))
    #expect(paths.contains("repo branch set-default"))
    #expect(paths.contains("repo collaborator list"))
    #expect(paths.contains("repo collaborator add"))
    #expect(paths.contains("repo collaborator remove"))
    #expect(paths.contains("repo secret list"))
    #expect(paths.contains("repo secret add"))
    #expect(paths.contains("repo secret remove"))
    #expect(!paths.contains("help"))
  }

  @Test func authAgentServiceCommandsAreMacOSOnly() throws {
    let document = try CapabilityCatalog.document()
    let serviceCommands = document.commands.filter {
      $0.path.starts(with: ["auth", "agent", "service"])
    }
    #expect(serviceCommands.count == 6)
    #expect(serviceCommands.allSatisfy { $0.platforms == ["macos"] })
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
    let repoCreate = try #require(
      document.commands.first { $0.path == ["repo", "create"] }
    )
    let repoDelete = try #require(
      document.commands.first { $0.path == ["repo", "delete"] }
    )
    let repoSetDefault = try #require(
      document.commands.first { $0.path == ["repo", "branch", "set-default"] }
    )
    let collaboratorList = try #require(
      document.commands.first { $0.path == ["repo", "collaborator", "list"] }
    )
    let collaboratorAdd = try #require(
      document.commands.first { $0.path == ["repo", "collaborator", "add"] }
    )
    let collaboratorRemove = try #require(
      document.commands.first { $0.path == ["repo", "collaborator", "remove"] }
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
    let pipelineLogs = try #require(
      document.commands.first { $0.path == ["pipeline", "logs"] }
    )
    let pipelineRetry = try #require(
      document.commands.first { $0.path == ["pipeline", "retry"] }
    )
    let pipelineRun = try #require(
      document.commands.first { $0.path == ["pipeline", "run"] }
    )
    let pipelineCancel = try #require(
      document.commands.first { $0.path == ["pipeline", "cancel"] }
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
    #expect(repoCreate.access == .write)
    #expect(repoCreate.authenticationRequired)
    #expect(repoCreate.options.contains { $0.names == ["--default-branch"] })
    #expect(repoCreate.options.contains { $0.names == ["--source"] })
    #expect(repoCreate.options.contains { $0.names == ["--repo-did"] })
    #expect(repoDelete.access == .write)
    #expect(repoDelete.authenticationRequired)
    #expect(repoDelete.options.contains { $0.names == ["--yes"] })
    #expect(repoSetDefault.access == .write)
    #expect(repoSetDefault.authenticationRequired)
    #expect(repoSetDefault.arguments.map(\.name) == ["branch", "repository"])
    #expect(repoSetDefault.options.contains { $0.names == ["--json"] })
    #expect(collaboratorList.access == .read)
    #expect(!collaboratorList.authenticationRequired)
    #expect(collaboratorList.options.contains { $0.names == ["-L", "--limit"] })
    #expect(collaboratorAdd.access == .write)
    #expect(collaboratorAdd.authenticationRequired)
    #expect(collaboratorAdd.arguments.count == 2)
    #expect(collaboratorRemove.access == .write)
    #expect(collaboratorRemove.authenticationRequired)
    #expect(collaboratorRemove.options.contains { $0.names == ["--yes"] })
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
    #expect(pipelineLogs.access == .read)
    #expect(!pipelineLogs.authenticationRequired)
    #expect(
      pipelineLogs.arguments == [
        CapabilityArgument(name: "pipeline-id", required: true, repeating: false)
      ]
    )
    #expect(
      pipelineLogs.options.contains {
        $0.names == ["--workflow"] && $0.repeating
      }
    )
    #expect(pipelineRetry.access == .write)
    #expect(pipelineRetry.authenticationRequired)
    #expect(pipelineRetry.options.contains { $0.names == ["--workflow"] })
    #expect(pipelineRun.access == .write)
    #expect(pipelineRun.authenticationRequired)
    #expect(
      pipelineRun.arguments == [
        CapabilityArgument(name: "commit", required: true, repeating: false)
      ]
    )
    #expect(
      pipelineRun.options.contains {
        $0.names == ["--workflow"] && $0.repeating
      }
    )
    #expect(
      pipelineRun.options.contains {
        $0.names == ["--input"] && $0.repeating
      }
    )
    #expect(pipelineCancel.access == .write)
    #expect(pipelineCancel.authenticationRequired)
    #expect(
      pipelineCancel.arguments == [
        CapabilityArgument(name: "pipeline-id", required: true, repeating: false)
      ]
    )
    #expect(
      pipelineCancel.options.contains {
        $0.names == ["--workflow"] && $0.repeating
      }
    )
  }

  @Test func capabilityJSONRoundTrips() throws {
    let document = try CapabilityCatalog.document()
    let output = try CLIFormatter.plain.json(document)
    let decoded = try JSONDecoder().decode(CapabilityDocument.self, from: Data(output.utf8))

    #expect(decoded == document)
  }

  @Test func repositorySecretCapabilitiesRequireAuthenticationAndNeverAcceptAValueOption() throws {
    let document = try CapabilityCatalog.document()
    let list = try #require(
      document.commands.first { $0.path == ["repo", "secret", "list"] }
    )
    let add = try #require(
      document.commands.first { $0.path == ["repo", "secret", "add"] }
    )
    let remove = try #require(
      document.commands.first { $0.path == ["repo", "secret", "remove"] }
    )

    #expect(list.access == .read)
    #expect(list.authenticationRequired)
    #expect(list.arguments == [CapabilityArgument(name: "repository", required: false, repeating: false)])
    #expect(add.access == .write)
    #expect(add.authenticationRequired)
    #expect(add.arguments.map(\.name) == ["repository", "key"])
    #expect(!add.options.flatMap(\.names).contains("--value"))
    #expect(remove.access == .write)
    #expect(remove.authenticationRequired)
    #expect(remove.options.contains { $0.names == ["--yes"] })
  }

  @Test func tmbEnrollmentCapabilitiesNeverAcceptASecretOption() throws {
    let document = try CapabilityCatalog.document()
    let enroll = try #require(
      document.commands.first { $0.path == ["auth", "agent", "tmb", "enroll"] }
    )
    let revoke = try #require(
      document.commands.first { $0.path == ["auth", "agent", "tmb", "revoke"] }
    )

    #expect(enroll.access == .write)
    #expect(!enroll.authenticationRequired)
    #expect(enroll.options.flatMap(\.names).contains("--origin"))
    #expect(enroll.options.flatMap(\.names).contains("--name"))
    #expect(!enroll.options.flatMap(\.names).contains("--secret"))
    #expect(!enroll.options.flatMap(\.names).contains("--credential"))
    #expect(revoke.options.flatMap(\.names).contains("--yes"))
  }
}
