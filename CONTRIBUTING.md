# Contributing

Contributions to swift-tangled are welcome. This project currently prioritizes
the reusable `SwiftTangled` SDK and practical `tng` command-line workflows.

## Report Bugs and Request Features

Use [Tangled Issues](https://tangled.org/nnabeyang.tngl.sh/swift-tangled/issues)
for bug reports and feature requests. Search existing issues first to avoid
duplicates. The maintainers may use YouTrack for internal planning, but
contributors do not need a YouTrack ticket.

Bug reports should include the swift-tangled version or commit, the operating
system and Swift version, steps to reproduce the problem, expected behavior,
and actual behavior. Remove tokens, session data, repository credentials, and
other private information before posting.

## Development

See the [README](README.md#requirements) for the supported environment and
dependency requirements.

### macOS

From the repository root, run:

```sh
./format.sh
swift build
swift test
```

`format.sh` uses `swift-format` from the active Xcode installation.

Test the installation flow without changing the current installation with:

```sh
./Tests/install-script-tests.sh
```

### Linux Dev Container

Open the repository in VS Code and run **Dev Containers: Reopen in Container**.
The container uses Swift 6.3.2 on Ubuntu Noble and mounts both the current
worktree and its Git common directory at their original absolute paths, so it
also works when the repository is opened from a Git worktree.

Inside the container, run:

```sh
swift package resolve
swift build
swift test
swift run tng --version
```

Formatting currently requires macOS. The container adds `~/.swiftpm/bin` to
`PATH`, so `tng` is available directly after running `./install.sh`.

The generated `.devcontainer/.env` contains only host path information and is
not tracked. Git credentials and SSH agent access use VS Code Dev Containers'
built-in forwarding. Do not copy tokens, `.netrc`, or private keys into the
repository or container image.

On Linux, `tng` stores its OAuth session at
`$XDG_STATE_HOME/tng/session.json`, or at
`$HOME/.local/state/tng/session.json` when `XDG_STATE_HOME` is unset, empty, or
relative. The directory is created with mode `0700` and the file with mode
`0600`; writes use atomic replacement and reject unsafe links, file types,
ownership, and permissions. Remove the session with `tng auth logout`.

The session contains OAuth tokens and DPoP key material in plaintext. Keep the
host filesystem and backups encrypted, and do not sync or archive the file. It
is never copied into the Dev Container image or repository. macOS stores the
session in Keychain.

OAuth login uses a loopback callback server. In a Dev Container or remote
environment, pass `--no-browser` and `--callback-port PORT`, open the printed
URL on the host, and forward that port when it is not forwarded automatically.

### Tangled Spindle CI

The Linux CI workflow runs on Tangled Spindle for pushes to `main`, pull
requests targeting `main`, and manual runs. It builds a Swift 6.3.2 Ubuntu
Noble environment with the same system-package installer used by the Dev
Container, then runs:

```sh
swift build
swift test
swift run --skip-build tng --version
swift run --skip-build tng capabilities --json
swift run --skip-build tng repo view nnabeyang.tngl.sh/swift-tangled --json
```

Open the repository's **Pipelines** page to inspect each step and its logs, or
to start the `linux` workflow manually. Environment preparation, build, test,
and smoke checks rely on Spindle's workflow timeout so a slow but progressing
command is not interrupted by a shorter repository-level limit.

The workflow does not require credentials. If a future workflow needs a
secret, add it through the Tangled repository settings. Never put tokens, SSH
keys, `.env` contents, or other credentials in a workflow file, command,
pipeline log, or artifact.

## Design Guidelines

- Put reusable behavior and domain logic in `SwiftTangled`.
- Keep `tng` focused on argument parsing, output, and orchestration.
- Preserve the dependency direction from clients to `SwiftTangled`, then to
  `swift-atproto` and AT Protocol services.
- Discuss new third-party dependencies in an issue before adding them.
- Use Bobbin for reads and authenticated AT Protocol APIs for writes. Do not
  scrape the Tangled web interface.

The generated files `Sources/TangledLexicons/XRPCAPIClient.swift` and
`Sources/TangledLexicons/UnknownATPValue.swift` must not be edited directly.
Update `.atproto.json` when changing Lexicon inputs, then run `./generate.sh`
and commit the generated files together with `.atproto-lock.json`.

## Pull Requests

Fork the
[swift-tangled repository](https://tangled.org/nnabeyang.tngl.sh/swift-tangled)
on Tangled, create a focused branch in the fork, and push the branch. From the
fork's checkout, create a Tangled Pull Request against the upstream repository:

```sh
git push origin feature/my-change
tng pr create \
  --repo nnabeyang.tngl.sh/swift-tangled \
  --base main \
  --head feature/my-change \
  --title "Describe the change" \
  --body "Why this change is useful"
```

Git `origin` must be the Tangled fork and Tangled must record it as a fork of
the upstream repository. Both the source and target commits must already exist
locally. If `tng` is not installed, run `./install.sh` from this repository
before creating the Pull Request.

Before opening a Pull Request:

- Keep the change focused and explain the user-visible reason for it.
- Add focused Swift Testing coverage for changed public SDK or CLI behavior.
- Run the formatter, build, and complete test suite.
- Include generated source changes only when their Lexicon inputs changed.
- Avoid unrelated formatting, generated-by text, and co-author signatures.

Open an issue before starting a large feature or architectural change so its
scope and approach can be agreed on first.

Tangled reviews are organized into immutable rounds. After addressing review
feedback, push the updated branch and explicitly resubmit it as a new round in
Tangled. Pushing commits alone does not replace the round already under review.
