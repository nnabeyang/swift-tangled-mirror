import ArgumentParser

enum CompletionShellArgument: String, CaseIterable, ExpressibleByArgument {
  case bash
  case zsh
  case fish

  var completionShell: CompletionShell {
    CompletionShell(rawValue: rawValue)!
  }
}

struct CompletionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "completion",
    abstract: "Generate a shell completion script",
    discussion: """
      Install a generated script using your shell's completion directory.

      Bash:
        mkdir -p ~/.bash_completions
        tng completion bash > ~/.bash_completions/tng.bash
        Add "source ~/.bash_completions/tng.bash" to ~/.bashrc or ~/.bash_profile.

      Zsh:
        mkdir -p ~/.zsh/completion
        tng completion zsh > ~/.zsh/completion/_tng
        Add these lines to ~/.zshrc:
          fpath=(~/.zsh/completion $fpath)
          autoload -U compinit
          compinit

      Fish:
        mkdir -p ~/.config/fish/completions
        tng completion fish > ~/.config/fish/completions/tng.fish
      """
  )

  @Argument(help: "Shell to generate a completion script for")
  var shell: CompletionShellArgument

  func run() async throws {
    try await runCLICommand {
      CLICommandOutput(stdout: Tng.completionScript(for: shell.completionShell) + "\n")
    }
  }
}
