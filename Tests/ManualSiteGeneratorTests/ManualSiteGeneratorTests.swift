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

  @Test func rendersVisibleCommandsAndStructuredArguments() throws {
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
    let page = try string(files, path: "manual/tng_repo_list/index.html")

    #expect(files["manual/tng/index.html"] != nil)
    #expect(files["manual/tng_repo/index.html"] != nil)
    #expect(page.contains("tng repo list [&lt;owner&gt;] [--limit &lt;limit&gt;]"))
    #expect(page.contains("-L, --limit &lt;limit&gt;"))
    #expect(page.contains("Default: <code>30</code>"))
    #expect(page.contains("Values: <code>10</code>, <code>30</code>"))
    #expect(!page.contains("--internal"))
  }

  @Test func escapesCommandContentAndAttributes() throws {
    let command = CommandInfo(
      commandName: "unsafe",
      abstract: #"<script>alert("x")</script>"#,
      arguments: [
        ArgumentInfo(
          abstract: "A & B",
          isOptional: false,
          kind: "positional",
          valueName: "value"
        )
      ]
    )
    let files = try renderer(commands: [command]).render()
    let page = try string(files, path: "manual/tng_unsafe/index.html")

    #expect(!page.contains("<script>alert"))
    #expect(page.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"))
    #expect(page.contains("A &amp; B"))
  }

  @Test func omitsHiddenCommandsAndProducesStableOutput() throws {
    let visible = CommandInfo(commandName: "visible")
    let hidden = CommandInfo(commandName: "hidden", shouldDisplay: false)
    let renderer = renderer(commands: [visible, hidden])

    let first = try renderer.render()
    let second = try renderer.render()

    #expect(first == second)
    #expect(first["manual/tng_visible/index.html"] != nil)
    #expect(first["manual/tng_hidden/index.html"] == nil)
  }

  @Test func generatedLinksUseSubpathSafeRelativeURLs() throws {
    let command = CommandInfo(
      commandName: "repo",
      subcommands: [CommandInfo(commandName: "view")]
    )
    let files = try renderer(commands: [command]).render()
    let landing = try string(files, path: "index.html")
    let nested = try string(files, path: "manual/tng_repo_view/index.html")

    #expect(landing.contains(#"href="manual/tng/""#))
    #expect(nested.contains(#"href="../../assets/manual.css""#))
    #expect(nested.contains(#"href="../tng_repo/""#))
    #expect(nested.contains(#"href="../tng/""#))
  }

  private func renderer(commands: [CommandInfo]) -> ManualSiteRenderer {
    ManualSiteRenderer(
      tool: ToolInfo(
        serializationVersion: 0,
        command: CommandInfo(
          commandName: "tng",
          abstract: "Tangled CLI",
          subcommands: commands
        )
      ),
      source: ManualSiteSource(
        landingHTML: "<h1>Manual</h1>",
        stylesheet: "body {}",
        javascript: ""
      )
    )
  }

  private func string(_ files: [String: Data], path: String) throws -> String {
    let data = try #require(files[path])
    return try #require(String(data: data, encoding: .utf8))
  }
}
