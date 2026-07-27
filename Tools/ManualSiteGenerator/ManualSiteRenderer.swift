import Foundation

struct ManualSiteSource: Sendable {
  let landingHTML: String
  let stylesheet: String
  let javascript: String
}

struct CommandPage: Sendable {
  let path: [String]
  let command: CommandInfo

  var title: String { path.joined(separator: " ") }
  var slug: String { path.joined(separator: "_") }
}

struct ManualSiteRenderer: Sendable {
  let tool: ToolInfo
  let source: ManualSiteSource

  func render() throws -> [String: Data] {
    try tool.validate()
    let pages = visiblePages(command: tool.command, parents: [])
    guard let rootPage = pages.first else {
      throw ManualSiteError.missingRootCommand
    }

    var files: [String: Data] = [
      "assets/manual.css": Data(source.stylesheet.utf8),
      "assets/manual.js": Data(source.javascript.utf8),
    ]

    files["index.html"] = Data(
      pageShell(
        title: "tng CLI manual",
        description: "Command-line reference and getting started guide for tng.",
        rootPrefix: "",
        navigation: navigation(pages: pages, currentSlug: nil, rootPrefix: ""),
        content: source.landingHTML
      ).utf8
    )

    for page in pages {
      let path = "manual/\(page.slug)/index.html"
      files[path] = Data(
        pageShell(
          title: "\(page.title) manual",
          description: page.command.abstract ?? "Reference for \(page.title).",
          rootPrefix: "../../",
          navigation: navigation(
            pages: pages,
            currentSlug: page.slug,
            rootPrefix: "../../"
          ),
          content: commandContent(page: page, rootPage: rootPage, pages: pages)
        ).utf8
      )
    }

    return files
  }

  private func visiblePages(command: CommandInfo, parents: [String]) -> [CommandPage] {
    guard command.shouldDisplay else { return [] }
    let path = parents + [command.commandName]
    return [CommandPage(path: path, command: command)]
      + command.subcommands.flatMap { visiblePages(command: $0, parents: path) }
  }

  private func pageShell(
    title: String,
    description: String,
    rootPrefix: String,
    navigation: String,
    content: String
  ) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="description" content="\(escapeAttribute(description))">
      <title>\(escapeHTML(title)) · tng CLI</title>
      <link rel="stylesheet" href="\(rootPrefix)assets/manual.css">
      <script src="\(rootPrefix)assets/manual.js" defer></script>
    </head>
    <body>
      <a class="skip-link" href="#content">Skip to content</a>
      <header class="site-header">
        <a class="brand" href="\(rootPrefix)">tng</a>
        <span class="site-title">CLI manual</span>
        <a class="repository-link" href="https://tangled.org/nnabeyang.tngl.sh/swift-tangled">Repository</a>
        <button class="nav-toggle" type="button" aria-expanded="false" aria-controls="manual-navigation">
          Commands
        </button>
      </header>
      <div class="site-layout">
        \(navigation)
        <main id="content" tabindex="-1">
          \(content)
          <footer>
            Generated from the <code>tng</code> command definitions.
          </footer>
        </main>
      </div>
    </body>
    </html>
    """
  }

  private func navigation(
    pages: [CommandPage],
    currentSlug: String?,
    rootPrefix: String
  ) -> String {
    let root = pages[0]
    let children = Array(pages.dropFirst())
    let groups = Dictionary(grouping: children) { page in
      page.path.count > 1 ? page.path[1] : page.path[0]
    }
    let orderedGroups = root.command.subcommands
      .filter(\.shouldDisplay)
      .map(\.commandName)

    var result = """
        <nav id="manual-navigation" class="manual-navigation" aria-label="Command reference">
          <label for="command-filter">Filter commands</label>
          <input id="command-filter" type="search" placeholder="Search commands" autocomplete="off">
          <ul class="command-tree">
            \(navigationItem(page: root, currentSlug: currentSlug, rootPrefix: rootPrefix))
      """

    for groupName in orderedGroups {
      guard let groupPages = groups[groupName] else { continue }
      let sorted = groupPages.sorted {
        if $0.path.count == $1.path.count {
          return $0.title < $1.title
        }
        return $0.path.count < $1.path.count
      }
      let groupLabel = sorted.first { $0.path.count == 2 }?.title ?? "tng \(groupName)"
      result += """
            <li class="command-group" data-command-group>
              <span>\(escapeHTML(groupLabel))</span>
              <ul>
        """
      for page in sorted {
        result += navigationItem(
          page: page,
          currentSlug: currentSlug,
          rootPrefix: rootPrefix
        )
      }
      result += """
              </ul>
            </li>
        """
    }

    result += """
          </ul>
          <p class="no-results" hidden>No matching commands.</p>
        </nav>
      """
    return result
  }

  private func navigationItem(
    page: CommandPage,
    currentSlug: String?,
    rootPrefix: String
  ) -> String {
    let current = page.slug == currentSlug ? #" aria-current="page""# : ""
    let searchable = "\(page.title) \(page.command.abstract ?? "")"
    return """
        <li data-command-item data-search="\(escapeAttribute(searchable.lowercased()))">
          <a href="\(rootPrefix)manual/\(page.slug)/"\(current)>\(escapeHTML(page.title))</a>
        </li>
      """
  }

  private func commandContent(
    page: CommandPage,
    rootPage: CommandPage,
    pages: [CommandPage]
  ) -> String {
    let visibleArguments = page.command.arguments.filter(\.shouldDisplay)
    let positionals = visibleArguments.filter { $0.kind == "positional" }
    let options = visibleArguments.filter { $0.kind != "positional" }
    let subcommandPaths = page.command.subcommands
      .filter(\.shouldDisplay)
      .map { page.path + [$0.commandName] }
    let pageByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })

    var result = breadcrumb(path: page.path, pages: pages)
    result += "<h1><code>\(escapeHTML(page.title))</code></h1>"
    if let abstract = page.command.abstract {
      result += "<p class=\"lead\">\(escapeHTML(abstract))</p>"
    }

    result += """
        <section>
          <h2>Usage</h2>
          <pre class="usage"><code>\(escapeHTML(usage(page: page)))</code></pre>
        </section>
      """

    if let discussion = page.command.discussion, !discussion.isEmpty {
      result += """
          <section>
            <h2>Description</h2>
            \(renderDiscussion(discussion))
          </section>
        """
    }

    if !subcommandPaths.isEmpty {
      result += "<section><h2>Available commands</h2><dl class=\"command-list\">"
      for path in subcommandPaths {
        guard let subcommand = pageByPath[path] else { continue }
        result += """
            <div>
              <dt><a href="../\(subcommand.slug)/"><code>\(escapeHTML(subcommand.title))</code></a></dt>
              <dd>\(escapeHTML(subcommand.command.abstract ?? ""))</dd>
            </div>
          """
      }
      result += "</dl></section>"
    }

    if !positionals.isEmpty {
      result += argumentSection(title: "Arguments", arguments: positionals)
    }
    if !options.isEmpty {
      result += argumentSection(title: "Options", arguments: options)
    }

    if page.slug != rootPage.slug {
      result += """
          <p class="root-reference">
            See also <a href="../\(rootPage.slug)/"><code>\(escapeHTML(rootPage.title))</code></a>.
          </p>
        """
    }
    return result
  }

  private func breadcrumb(path: [String], pages: [CommandPage]) -> String {
    let pagesByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
    var parts: [String] = []
    for index in path.indices {
      let partial = Array(path[...index])
      guard let page = pagesByPath[partial] else { continue }
      if index == path.indices.last {
        parts.append("<span aria-current=\"page\">\(escapeHTML(path[index]))</span>")
      } else {
        parts.append(
          "<a href=\"../\(page.slug)/\">\(escapeHTML(path[index]))</a>"
        )
      }
    }
    return """
        <nav class="breadcrumbs" aria-label="Breadcrumb">
          \(parts.joined(separator: "<span aria-hidden=\"true\">/</span>"))
        </nav>
      """
  }

  private func usage(page: CommandPage) -> String {
    let suffix = page.command.arguments
      .filter(\.shouldDisplay)
      .map(usageComponent)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return suffix.isEmpty ? page.title : "\(page.title) \(suffix)"
  }

  private func usageComponent(argument: ArgumentInfo) -> String {
    let repeated = argument.isRepeating ? "..." : ""
    let component: String
    if argument.kind == "positional" {
      component = "<\(argument.valueName)>\(repeated)"
    } else {
      let name =
        argument.preferredName?.spelling
        ?? argument.names.last?.spelling
        ?? argument.valueName
      if argument.kind == "option" {
        component = "\(name) <\(argument.valueName)>\(repeated)"
      } else {
        component = "\(name)\(repeated)"
      }
    }
    return argument.isOptional ? "[\(component)]" : component
  }

  private func argumentSection(title: String, arguments: [ArgumentInfo]) -> String {
    var result = "<section><h2>\(title)</h2><dl class=\"arguments\">"
    for argument in arguments {
      result += "<div><dt><code>\(escapeHTML(argumentIdentity(argument)))</code></dt><dd>"
      if let abstract = argument.abstract {
        result += "<p>\(escapeHTML(abstract))</p>"
      }
      if let discussion = argument.discussion {
        result += renderDiscussion(discussion)
      }
      var metadata: [String] = []
      if let defaultValue = argument.defaultValue {
        metadata.append("Default: <code>\(escapeHTML(defaultValue))</code>")
      }
      if argument.isRepeating {
        metadata.append("Repeatable")
      }
      if let allValues = argument.allValues, !allValues.isEmpty {
        let values = allValues.map { "<code>\(escapeHTML($0))</code>" }
          .joined(separator: ", ")
        metadata.append("Values: \(values)")
      }
      if !metadata.isEmpty {
        result += "<p class=\"argument-metadata\">\(metadata.joined(separator: " · "))</p>"
      }
      result += "</dd></div>"
    }
    result += "</dl></section>"
    return result
  }

  private func argumentIdentity(_ argument: ArgumentInfo) -> String {
    if argument.kind == "positional" {
      return "<\(argument.valueName)>"
    }
    let names = argument.names.map(\.spelling)
    let renderedNames = names.isEmpty ? argument.valueName : names.joined(separator: ", ")
    if argument.kind == "option" {
      return "\(renderedNames) <\(argument.valueName)>"
    }
    return renderedNames
  }

  private func renderDiscussion(_ discussion: String) -> String {
    let paragraphs = discussion.components(separatedBy: "\n\n")
    return paragraphs.map { paragraph in
      "<p class=\"discussion\">\(escapeHTML(paragraph).replacingOccurrences(of: "\n", with: "<br>"))</p>"
    }.joined()
  }
}

func escapeHTML(_ value: String) -> String {
  value
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&#39;")
}

func escapeAttribute(_ value: String) -> String {
  escapeHTML(value)
}
