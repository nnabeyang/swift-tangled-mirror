import Foundation

struct CommandPage: Sendable {
  let path: [String]
  let command: CommandInfo

  var isRoot: Bool { path.count == 1 }
  var title: String { path.joined(separator: " ") }
  var sourceName: String {
    isRoot ? "CommandReference" : path.joined(separator: "-")
  }
}

struct ManualSiteRenderer: Sendable {
  let tool: ToolInfo

  func render() throws -> [String: Data] {
    try tool.validate()
    let pages = visiblePages(command: tool.command, parents: [])
    guard let rootPage = pages.first else {
      throw ManualSiteError.missingRootCommand
    }
    let pagesByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
    var files: [String: Data] = [:]

    for page in pages {
      let markdown = commandMarkdown(
        page: page,
        rootPage: rootPage,
        pagesByPath: pagesByPath
      )
      files["catalog/\(page.sourceName).md"] = Data(markdown.utf8)
    }

    return files
  }

  private func visiblePages(command: CommandInfo, parents: [String]) -> [CommandPage] {
    guard command.shouldDisplay else { return [] }
    let path = parents + [command.commandName]
    return [CommandPage(path: path, command: command)]
      + command.subcommands.flatMap { visiblePages(command: $0, parents: path) }
  }

  private func commandMarkdown(
    page: CommandPage,
    rootPage: CommandPage,
    pagesByPath: [[String]: CommandPage]
  ) -> String {
    var result = "# \(page.isRoot ? "Command reference" : page.title)\n\n"
    if let abstract = page.command.abstract {
      result += "\(markdownText(abstract))\n\n"
    }

    result += "## Usage\n\n```console\n\(usage(page: page))\n```\n"

    if let discussion = page.command.discussion, !discussion.isEmpty {
      result += "\n## Overview\n\n\(discussionMarkdown(discussion))\n"
    }

    let visibleArguments = page.command.arguments.filter(\.shouldDisplay)
    let positionals = visibleArguments.filter { $0.kind == "positional" }
    let options = visibleArguments.filter { $0.kind != "positional" }
    if !positionals.isEmpty {
      result += argumentSection(title: "Arguments", arguments: positionals)
    }
    if !options.isEmpty {
      result += argumentSection(title: "Options", arguments: options)
    }

    let children = page.command.subcommands
      .filter(\.shouldDisplay)
      .compactMap { pagesByPath[page.path + [$0.commandName]] }
    if !children.isEmpty {
      result += "\n## Topics\n\n### Subcommands\n\n"
      result += children.map { "- <doc:\($0.sourceName)>" }.joined(separator: "\n")
      result += "\n"
    }

    if !page.isRoot {
      result += "\n## See Also\n\n- <doc:\(page.path.count == 2 ? rootPage.sourceName : parentPage(for: page, rootPage: rootPage).sourceName)>\n"
    }
    return result + "\n"
  }

  private func parentPage(for page: CommandPage, rootPage: CommandPage) -> CommandPage {
    let parentPath = Array(page.path.dropLast())
    if parentPath.count == 1 { return rootPage }
    return CommandPage(path: parentPath, command: CommandInfo(commandName: parentPath.last ?? "tng"))
  }

  private func argumentSection(title: String, arguments: [ArgumentInfo]) -> String {
    var result = "\n## \(title)\n"
    for argument in arguments {
      result += "\n### \(argumentIdentity(argument))\n\n"
      if let abstract = argument.abstract {
        result += "\(markdownText(abstract))\n\n"
      }
      if let discussion = argument.discussion, !discussion.isEmpty {
        result += "\(discussionMarkdown(discussion))\n\n"
      }
      var metadata: [String] = []
      if let defaultValue = argument.defaultValue {
        metadata.append("Default: `\(inlineCode(defaultValue))`")
      }
      if argument.isRepeating { metadata.append("Repeatable") }
      if let allValues = argument.allValues, !allValues.isEmpty {
        metadata.append("Values: " + allValues.map { "`\(inlineCode($0))`" }.joined(separator: ", "))
      }
      if !metadata.isEmpty {
        result += "- " + metadata.joined(separator: "\n- ") + "\n"
      }
    }
    return result
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
      let name = argument.preferredName?.spelling ?? argument.names.last?.spelling ?? argument.valueName
      component =
        argument.kind == "option"
        ? "\(name) <\(argument.valueName)>\(repeated)"
        : "\(name)\(repeated)"
    }
    return argument.isOptional ? "[\(component)]" : component
  }

  private func argumentIdentity(_ argument: ArgumentInfo) -> String {
    if argument.kind == "positional" { return "<\(argument.valueName)>" }
    let names = argument.names.map(\.spelling)
    let renderedNames = names.isEmpty ? argument.valueName : names.joined(separator: ", ")
    return argument.kind == "option" ? "\(renderedNames) <\(argument.valueName)>" : renderedNames
  }

  private func discussionMarkdown(_ discussion: String) -> String {
    discussion
      .components(separatedBy: "\n\n")
      .map { paragraph in
        paragraph.split(separator: "\n", omittingEmptySubsequences: false).map { line in
          let text = String(line)
          if text.hasPrefix("  ") {
            return "    \(markdownText(String(text.dropFirst(2))))"
          }
          return markdownText(text)
        }.joined(separator: "  \n")
      }
      .joined(separator: "\n\n")
  }

  private func markdownText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "`", with: "\\`")
      .replacingOccurrences(of: "*", with: "\\*")
      .replacingOccurrences(of: "_", with: "\\_")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
      .replacingOccurrences(of: "<", with: "\\<")
      .replacingOccurrences(of: ">", with: "\\>")
  }

  private func inlineCode(_ value: String) -> String {
    value.replacingOccurrences(of: "`", with: "\\`")
  }

}
