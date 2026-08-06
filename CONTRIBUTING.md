# Contributing

Contributions to swift-tangled are welcome. This project currently prioritizes
practical `tng` command-line workflows.

## Report Bugs and Request Features

Use [Tangled Issues](https://tangled.org/nnabeyang.tngl.sh/swift-tangled/issues)
for bug reports and feature requests. Search existing issues first to avoid
duplicates.

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
The container uses Swift 6.3.3 on Ubuntu Noble and mounts both the current
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

### CI

Tangled is the canonical repository. The maintainers mirror Pull Request
source commits to the read-only
[GitHub repository](https://github.com/nnabeyang/swift-tangled-mirror), where
the Linux workflow runs for every pushed branch and can also be started
manually. It builds a Swift 6.3.3 Ubuntu Noble environment with the same
system-package installer used by the Dev Container, then runs:

```sh
swift build
swift test
./scripts/generate-documentation.sh --check
swift run --skip-build tng --version
swift run --skip-build tng capabilities --json
swift run --skip-build tng repo view nnabeyang.tngl.sh/swift-tangled --json
```

Open the mirror's **Actions** page to inspect each step and its logs, or to
start the `Linux` workflow manually. Pull Requests, Issues, and Discussions
remain on Tangled; the GitHub repository is only a source mirror and CI
runner.

The workflow does not require credentials. If a future workflow needs a
secret, add it through the GitHub repository settings. Never put tokens, SSH
keys, `.env` contents, or other credentials in a workflow file, command, log,
or artifact.

The macOS workflow runs on the repository's assigned Spindle with an external
worker advertising Xcode 26.6. It uses that Xcode toolchain's SwiftPM to test
the package with quiet output. The default-on `KeychainIntegrationTests`
package trait is disabled because the worker is noninteractive; regular local
and GitHub test runs continue to exercise the login Keychain integration.

External workers execute workflow commands natively on their host instead of
inside a microVM. The worker may allow `refs/heads/*` only when its repository
policy is manual-only. Before starting the macOS workflow, review the exact
branch and commit and confirm that the manual dispatch targets them. Do not
enable push or Pull Request triggers for this workflow.

## Design Guidelines

- Put reusable behavior and domain logic in `SwiftTangled`.
- Keep `tng` focused on argument parsing, output, and orchestration.
- Preserve the dependency direction from clients to `SwiftTangled`, then to
  `swift-atproto` and AT Protocol services.
- `tng` is the package's only supported public product. `SwiftTangled` and
  `TangledLexicons` are internal targets, so their `public` declarations are
  not an external API. Do not add `.library` products for them without an
  explicit decision to support their external API stability.
- Discuss new third-party dependencies in an issue before adding them.
- Prefer authoritative PDS records for current repository, issue, pull request,
  and artifact state. Use Bobbin for indexed aggregate reads, Spindle for
  pipelines, Jetstream for live events, and authenticated AT Protocol APIs for
  writes. Do not scrape the Tangled web interface.

The generated files `Sources/TangledLexicons/XRPCAPIClient.swift` and
`Sources/TangledLexicons/UnknownATPValue.swift` must not be edited directly.
Update `.atproto.json` when changing Lexicon inputs, then run `./generate.sh`
and commit the generated files together with `.atproto-lock.json`.

`.atproto.json` lists only the NSIDs that `tng` actually uses. Covering every
Tangled NSID is not a goal, because `TangledLexicons` is not a published
library. Add an NSID when you write code that references it, and remove one
that nothing references any more. When a listed Lexicon `ref`s another
Lexicon, list that dependency too, as `com.atproto.repo.applyWrites` requires
`com.atproto.repo.defs`.

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
locally. Create the Pull Request with a released `tng` installed globally on
`PATH`. Do not use this checkout's `.build/debug/tng`, `.build/release/tng`, or
`swift run tng` for authenticated Tangled writes.

Before opening a Pull Request:

- Keep the change focused and explain the user-visible reason for it.
- Add focused Swift Testing coverage for changed public SDK or CLI behavior.
- Run the formatter, build, and complete test suite.
- Regenerate the CLI manual when command help changes.
- Include generated source changes only when their Lexicon inputs changed.
- Avoid unrelated formatting, generated-by text, and co-author signatures.

Open an issue before starting a large feature or architectural change so its
scope and approach can be agreed on first.

Tangled reviews are organized into immutable rounds. After addressing review
feedback, push the updated branch and explicitly resubmit it as a new round in
Tangled. Pushing commits alone does not replace the round already under review.

## CLI Manual

The static CLI manual under `docs/` is generated with Swift-DocC. Its command
reference is derived from ArgumentParser's command tree, while the guides and
landing page are maintained in `Documentation/Tng.docc/` and
`Documentation/Site/`.

Regenerate it after changing command names, help text, arguments, options, or
subcommands:

```sh
./scripts/generate-documentation.sh
```

Verify that the committed output is current without rewriting files:

```sh
./scripts/generate-documentation.sh --check
```

Documentation generation requires Swift 6.3.3. On macOS the script also pins
Xcode 26.6 build 17F113; on Linux it uses the `docc` executable from the Swift
toolchain. Do not edit generated files in `docs/` directly.
