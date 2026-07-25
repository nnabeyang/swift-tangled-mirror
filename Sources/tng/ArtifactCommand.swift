import ArgumentParser

struct ArtifactCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "artifact",
    abstract: "Work with artifacts attached to annotated Git tags",
    subcommands: [
      ArtifactListCommand.self,
      ArtifactViewCommand.self,
      ArtifactUploadCommand.self,
      ArtifactDownloadCommand.self,
      ArtifactDeleteCommand.self,
    ]
  )
}
