import ArgumentParser

struct EventsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "events",
    abstract: "Watch live Tangled events",
    subcommands: [
      EventsWatchCommand.self
    ]
  )
}
