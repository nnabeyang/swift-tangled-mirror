import ArgumentParser
import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct CLIOutputTests {
  @Test func reportsAPIError() {
    let report = errorReport(for: TangledError.invalidRequest("invalid value"))

    #expect(report.exitCode == .api)
    #expect(report.diagnostic == "API error: invalid request: invalid value\n")
  }

  @Test func reportsRecordConflictsAsAPIErrors() {
    let error = TangledError.conflict(nil)
    let report = errorReport(for: error)
    let jsonReport = jsonErrorReport(for: error)

    #expect(report.exitCode == .api)
    #expect(
      report.diagnostic
        == "API error: conflict: record changed since it was read; fetch the latest state and retry\n"
    )
    #expect(jsonReport.category == "api")
    #expect(jsonReport.code == "conflict")
    #expect(jsonReport.exitCode == CLIExitCode.api.rawValue)
  }

  @Test func reportsAuthenticationErrors() {
    let errors: [TangledError] = [
      .unauthorized,
      .insufficientScope("repo:sh.tangled.feed.star"),
      .oauthTimeout,
      .oauthStateMismatch,
      .oauthCancelled("denied"),
      .portBindFailure("unavailable"),
      .browserLaunchFailed("unavailable"),
      .keychainFailure(-1),
      .sessionStoreFailure("unavailable"),
    ]

    for error in errors {
      let report = errorReport(for: error)
      #expect(report.exitCode == .authentication)
      #expect(report.diagnostic.hasPrefix("Authentication error: "))
    }

    #expect(
      errorReport(for: TangledError.insufficientScope("repo:sh.tangled.feed.star"))
        .diagnostic
        == "Authentication error: missing OAuth scope: repo:sh.tangled.feed.star; run 'tng auth login <handle>' again\n"
    )
  }

  @Test func reportsCommandErrors() {
    #expect(
      errorReport(for: CLICommandError.authentication("session is invalid"))
        == CLIErrorReport(
          exitCode: .authentication,
          diagnostic: "Authentication error: session is invalid\n"
        )
    )
    #expect(
      errorReport(for: CLICommandError.authenticationRequired("sign in"))
        == CLIErrorReport(
          exitCode: .authentication,
          diagnostic: "Authentication required: sign in\n"
        )
    )
    #expect(
      errorReport(for: CLICommandError.git("origin is unavailable"))
        == CLIErrorReport(
          exitCode: .git,
          diagnostic: "Git error: origin is unavailable\n"
        )
    )
  }

  @Test func reportsUsageAndUnexpectedErrors() {
    let usage = errorReport(for: ValidationError("invalid option"))
    let unexpected = errorReport(for: UnexpectedTestError())

    #expect(usage.exitCode == .usage)
    #expect(usage.diagnostic == "Error: invalid option\n")
    #expect(unexpected.exitCode == .unexpected)
    #expect(unexpected.diagnostic == "Unexpected error: test failure\n")
  }

  @Test func reportsUnsuccessfulPipelineAsCommandFailure() {
    let report = errorReport(
      for: PipelineWatchFailure(
        pipelineID: "3mr7m2f6ger22",
        workflows: [
          PipelineWorkflow(
            id: "verify.yml",
            name: "verify.yml",
            status: .failed
          )
        ]
      )
    )

    #expect(report.exitCode == .unexpected)
    #expect(
      report.diagnostic
        == "Pipeline failed: pipeline 3mr7m2f6ger22 finished unsuccessfully (verify.yml:failed)\n"
    )
  }

  @Test func jsonErrorsExposeStableCategoriesCodesAndExitStatus() {
    #expect(jsonErrorReport(for: TangledError.notFound("record")).category == "api")
    #expect(jsonErrorReport(for: TangledError.notFound("record")).code == "not_found")
    #expect(
      jsonErrorReport(for: TangledError.notFound("record")).exitCode
        == CLIExitCode.api.rawValue
    )
    #expect(
      jsonErrorReport(for: CLICommandError.authenticationRequired("sign in")).code
        == "authentication_required"
    )
    #expect(jsonErrorReport(for: CLICommandError.git("missing origin")).code == "git_error")
    #expect(jsonErrorReport(for: ValidationError("invalid")).code == "invalid_usage")
  }
}

private struct UnexpectedTestError: Error, CustomStringConvertible {
  let description = "test failure"
}
