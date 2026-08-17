import Foundation
import Testing

@testable import ManualSiteGenerator

@Suite struct ManualSiteGeneratorTests {
  @Test func rejectsUnknownDumpHelpSerializationVersion() {
    let tool = ToolInfo(
      serializationVersion: 1,
      command: CommandInfo(commandName: "tng")
    )

    #expect(throws: ManualSiteError.self) {
      try tool.validate()
    }
  }

  @Test func rendersDocCArticles() throws {
    let repo = CommandInfo(
      commandName: "repo",
      abstract: "Work with repositories",
      subcommands: [
        CommandInfo(
          commandName: "list",
          abstract: "List repositories",
          arguments: [
            ArgumentInfo(
              abstract: "Repository owner",
              isOptional: true,
              kind: "positional",
              valueName: "owner"
            ),
            ArgumentInfo(
              abstract: "Maximum results",
              defaultValue: "30",
              allValues: ["10", "30"],
              isOptional: true,
              kind: "option",
              names: [
                ArgumentName(kind: "short", name: "L"),
                ArgumentName(kind: "long", name: "limit"),
              ],
              preferredName: ArgumentName(kind: "long", name: "limit"),
              valueName: "limit"
            ),
            ArgumentInfo(
              abstract: "Internal flag",
              isOptional: true,
              kind: "flag",
              names: [ArgumentName(kind: "long", name: "internal")],
              shouldDisplay: false,
              valueName: "internal"
            ),
          ]
        )
      ]
    )
    let files = try renderer(commands: [repo]).render()
    let page = try string(files, path: "catalog/tng-repo-list.md")

    #expect(files["catalog/CommandReference.md"] != nil)
    #expect(files["catalog/tng-repo.md"] != nil)
    #expect(files.keys.allSatisfy { !$0.hasPrefix("redirects/") })
    #expect(page.contains("tng repo list [<owner>] [--limit <limit>]"))
    #expect(page.contains("### <owner>"))
    #expect(page.contains("### -L, --limit <limit>"))
    #expect(!page.contains("### `<owner>`"))
    #expect(!page.contains("### `-L, --limit <limit>`"))
    #expect(page.contains("-L, --limit <limit>"))
    #expect(page.contains("Default: `30`"))
    #expect(page.contains("Values: `10`, `30`"))
    #expect(!page.contains("--internal"))
    #expect(page.contains("<doc:tng-repo>"))
  }

  @Test func inheritsRootOptionsAndAvoidsDuplicateArguments() throws {
    let rootOptions = [
      ArgumentInfo(
        abstract: "Use one stored account for this command",
        isOptional: true,
        kind: "option",
        names: [ArgumentName(kind: "long", name: "account")],
        valueName: "account"
      ),
      ArgumentInfo(
        abstract: "Show the version.",
        isOptional: true,
        kind: "flag",
        names: [ArgumentName(kind: "long", name: "version")],
        valueName: "version"
      ),
      ArgumentInfo(
        abstract: "Root positional must not be inherited",
        isOptional: true,
        kind: "positional",
        valueName: "root-value"
      ),
    ]
    let files = try renderer(
      commands: [
        CommandInfo(
          commandName: "auth",
          subcommands: [
            CommandInfo(
              commandName: "status",
              arguments: [
                ArgumentInfo(
                  abstract: "Show the version.",
                  isOptional: true,
                  kind: "flag",
                  names: [ArgumentName(kind: "long", name: "version")],
                  valueName: "version"
                )
              ]
            )
          ]
        )
      ],
      rootArguments: rootOptions
    ).render()
    let page = try string(files, path: "catalog/tng-auth-status.md")

    #expect(page.contains("tng auth status [--version] [--account <account>]"))
    #expect(page.contains("### --account <account>"))
    #expect(page.contains("Use one stored account for this command"))
    #expect(page.components(separatedBy: "### --version").count == 2)
    #expect(!page.contains("root-value"))
  }

  @Test func escapesMarkdownTextAndProducesStableOutput() throws {
    let command = CommandInfo(
      commandName: "unsafe",
      abstract: #"<script>alert("x")</script> *value*"#,
      discussion: "A & B\n\n  indented example",
      arguments: [
        ArgumentInfo(
          abstract: "A & B",
          isOptional: false,
          kind: "positional",
          valueName: "value"
        )
      ]
    )
    let renderer = renderer(commands: [command])
    let first = try renderer.render()
    let second = try renderer.render()
    let page = try string(first, path: "catalog/tng-unsafe.md")

    #expect(first == second)
    #expect(page.contains("\\<script\\>alert(\"x\")\\</script\\> \\*value\\*"))
    #expect(page.contains("    indented example"))
    #expect(page.contains("A & B"))
  }

  @Test func omitsHiddenCommandsAndUsesCommandReferenceForRoot() throws {
    let visible = CommandInfo(commandName: "visible")
    let hidden = CommandInfo(commandName: "hidden", shouldDisplay: false)
    let files = try renderer(commands: [visible, hidden]).render()

    #expect(files["catalog/CommandReference.md"] != nil)
    #expect(files["catalog/tng-visible.md"] != nil)
    #expect(files["catalog/tng-hidden.md"] == nil)
    #expect(files.keys.allSatisfy { !$0.hasPrefix("redirects/") })
  }

  private func renderer(
    commands: [CommandInfo],
    rootArguments: [ArgumentInfo] = []
  ) -> ManualSiteRenderer {
    ManualSiteRenderer(
      tool: ToolInfo(
        serializationVersion: 0,
        command: CommandInfo(
          commandName: "tng",
          abstract: "Tangled CLI",
          subcommands: commands,
          arguments: rootArguments
        )
      )
    )
  }

  private func string(_ files: [String: Data], path: String) throws -> String {
    let data = try #require(files[path])
    return try #require(String(data: data, encoding: .utf8))
  }
}
