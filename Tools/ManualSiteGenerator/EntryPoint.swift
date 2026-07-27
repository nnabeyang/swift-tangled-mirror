import Foundation

@main
struct ManualSiteGenerator {
  static func main() {
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      let writer = ManualSiteWriter()
      let tool = try writer.loadToolInfo(toolURL: options.tool)
      let source = try writer.loadSource(directory: options.source)
      let files = try ManualSiteRenderer(tool: tool, source: source).render()
      if options.check {
        try writer.check(files: files, outputDirectory: options.output)
        print("Manual site is up to date (\(files.count) files).")
      } else {
        try writer.write(files: files, outputDirectory: options.output)
        print("Generated manual site in \(options.output.path) (\(files.count) files).")
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      Foundation.exit(1)
    }
  }
}

private struct Options {
  let tool: URL
  let source: URL
  let output: URL
  let check: Bool

  init(arguments: [String]) throws {
    var values = arguments[...]
    var tool: String?
    var source: String?
    var output: String?
    var check = false

    while let argument = values.first {
      values.removeFirst()
      switch argument {
      case "--tool":
        tool = try Self.takeValue(for: argument, from: &values)
      case "--source":
        source = try Self.takeValue(for: argument, from: &values)
      case "--output":
        output = try Self.takeValue(for: argument, from: &values)
      case "--check":
        check = true
      default:
        throw ManualSiteError.invalidArguments("Unknown argument: \(argument)")
      }
    }

    guard let tool, let source, let output else {
      throw ManualSiteError.invalidArguments(
        "Usage: ManualSiteGenerator --tool PATH --source DIRECTORY --output DIRECTORY [--check]"
      )
    }
    self.tool = URL(fileURLWithPath: tool)
    self.source = URL(fileURLWithPath: source)
    self.output = URL(fileURLWithPath: output)
    self.check = check
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
