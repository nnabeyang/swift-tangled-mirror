import Foundation

@main
struct ManualSiteGenerator {
  static func main() {
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      let writer = ManualSiteWriter()
      let tool = try writer.loadToolInfo(toolURL: options.tool)
      let files = try ManualSiteRenderer(tool: tool).render()
      try writer.write(files: files, outputDirectory: options.output)
      print("Generated DocC sources in \(options.output.path) (\(files.count) files).")
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      Foundation.exit(1)
    }
  }
}

private struct Options {
  let tool: URL
  let output: URL

  init(arguments: [String]) throws {
    var values = arguments[...]
    var tool: String?
    var output: String?

    while let argument = values.first {
      values.removeFirst()
      switch argument {
      case "--tool":
        tool = try Self.takeValue(for: argument, from: &values)
      case "--output":
        output = try Self.takeValue(for: argument, from: &values)
      default:
        throw ManualSiteError.invalidArguments("Unknown argument: \(argument)")
      }
    }

    guard let tool, let output else {
      throw ManualSiteError.invalidArguments(
        "Usage: ManualSiteGenerator --tool PATH --output DIRECTORY"
      )
    }
    self.tool = URL(fileURLWithPath: tool)
    self.output = URL(fileURLWithPath: output)
  }

  private static func takeValue(
    for option: String,
    from values: inout ArraySlice<String>
  ) throws -> String {
    guard let value = values.first else {
      throw ManualSiteError.invalidArguments("Missing value for \(option)")
    }
    values.removeFirst()
    return value
  }
}
