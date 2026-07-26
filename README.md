# swift-tangled

`swift-tangled` provides the reusable `SwiftTangled` SDK and the `tng`
command-line tool for Tangled.

## Requirements

- macOS 15 or later, or Linux
- Swift 6.3 or later
- Git access to the package dependencies
- A Swift toolchain that supports `swift package experimental-install` when
  installing `tng` with the provided script

## Install `tng`

On an Apple Silicon Mac running macOS 15 or later, install the prebuilt binary
from the Tangled-hosted Homebrew tap:

```sh
brew tap nnabeyang/tap \
  https://tangled.org/nnabeyang.tngl.sh/homebrew-tap
brew install nnabeyang/tap/tng
```

To build and install from source instead, run this from the repository root:

```sh
./install.sh
```

The script builds `tng` in release mode and installs it into
`~/.swiftpm/bin`. Add that directory to `PATH` if necessary:

```sh
export PATH="$HOME/.swiftpm/bin:$PATH"
```

Run `./install.sh` again after updating the repository to replace the installed
executable.

## Quick Start

Confirm the installed version, sign in when a write operation requires
authentication, and inspect a repository:

```sh
tng --version
tng auth login YOUR_ATPROTO_HANDLE
tng auth status
tng repo view OWNER/REPOSITORY
```

Public read commands do not require a session. On macOS, authenticated sessions
are stored in Keychain. On Linux, they are stored as plaintext OAuth tokens and
DPoP key material in `$XDG_STATE_HOME/tng/session.json`, or
`$HOME/.local/state/tng/session.json` when `XDG_STATE_HOME` is not usable.
Protect that file and exclude it from backups and synchronization.

Use built-in help for command details:

```sh
tng --help
tng pr --help
tng capabilities --json
```

`capabilities` returns a versioned description of every executable command,
including its arguments, options, read/write classification, authentication
requirement, and supported platforms.

## CLI Features

| Command | Purpose |
| --- | --- |
| `tng auth` | Sign in, inspect the current session, or sign out |
| `tng repo` | View and browse repositories, branches, tags, files, and commits |
| `tng issue` | List, view, create, comment on, edit, close, and reopen issues |
| `tng pr` | List, view, diff, create, review, close, reopen, and merge pull requests |
| `tng pipeline` | List, inspect, and watch Spindle CI pipelines |
| `tng artifact` | Publish and download artifacts attached to annotated Git tags |
| `tng events` | Watch live Tangled records through Jetstream |
| `tng search` | Search public Tangled records |
| `tng api` | Call an allowlisted read-only Bobbin query |
| `tng completion` | Generate shell completion scripts |
| `tng capabilities` | Describe the CLI for tools and agents |

Most repository-aware commands infer the repository from the Git `origin`.
Pass `--repo OWNER/REPOSITORY` to target one explicitly. Commands intended for
automation support `--json` where documented by their help.

`tng` selects the read source according to the operation:

| Operation | Source |
| --- | --- |
| Repository listings | Repository owner's PDS |
| Repository, issue, and pull request records | Record owner's PDS, with Bobbin fallback for temporary PDS failures |
| Pull request listings with `--author` | Author and repository owner PDSes |
| Issue listings, pull request listings without `--author`, comments, and search | Bobbin |
| Artifact listings | Bobbin, merged with the signed-in account's PDS records |
| Pipelines | Spindle |
| Live events | Jetstream |

Bobbin-backed aggregate reads report a warning on standard error when index
coverage is unavailable or incomplete or when an initial query returns no
results. JSON output on standard output keeps the same schema when these
diagnostics are present.

### Pull Requests

Create a pull request after pushing its source branch:

```sh
git push origin feature/my-change
tng pr create --base main --head feature/my-change \
  --title "Describe the change" \
  --body "Why this change is useful"
```

To list one author's pull requests without waiting for Bobbin indexing, read
that author's PDS directly:

```sh
tng pr list OWNER/REPOSITORY --author AUTHOR_HANDLE
```

This mode resolves pull request status records from the author and repository
owner PDSes. Comment counts are not available: the table displays `-`, and
JSON output uses `-1`. Its pagination cursor is specific to the author,
repository, filters, and sort order; pass it back unchanged to the same mode.

The source and target commits must already exist locally. `tng` does not run
`git fetch` or `git push`. Use `tng pr view`, `tng pr diff`, `tng pr comment`,
`tng pr close`, `tng pr reopen`, and `tng pr merge` to continue the review
workflow. State changes use the pull request AT URI:

```sh
tng pr close PULL_REQUEST_AT_URI --json
tng pr reopen PULL_REQUEST_AT_URI --json
```

### Issues

```sh
tng issue list OWNER/REPOSITORY
tng issue view ISSUE_AT_URI --comments
tng issue create --repo OWNER/REPOSITORY --title "Describe the issue"
```

Issue write commands also support commenting, editing, closing, and reopening.

### Pipelines

```sh
tng pipeline list OWNER/REPOSITORY
tng pipeline view PIPELINE_ID --spindle spindle.tangled.sh
tng pipeline status PIPELINE_ID --spindle spindle.tangled.sh
tng pipeline watch PIPELINE_ID --repo OWNER/REPOSITORY
```

Pipeline commands discover the repository's current Spindle by default.
Use `--spindle` with `list`, `view`, `status`, or `watch` to select an endpoint
explicitly. `pipeline watch` reports workflow state changes until the pipeline
completes.

### Artifacts

Artifacts are files attached to remote annotated Git tags. Git remains
responsible for creating and pushing the tag:

```sh
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
tng artifact upload v1.0.0 .build/release/tng \
  --repo OWNER/REPOSITORY \
  --name tng
tng artifact download v1.0.0 tng \
  --repo OWNER/REPOSITORY \
  -o ./tng
```

When signed in, artifact listings merge the account's authoritative PDS
records with Bobbin results and prefer the PDS value for the same record URI.
Pagination cursors are opaque and must be passed back unchanged with the same
sort order. Cursors produced by earlier `tng` versions remain accepted.

### Live Events

Watch Tangled records through Jetstream, optionally filtering by collection or
DID:

```sh
tng events watch \
  --collection sh.tangled.feed.comment \
  --did did:plc:example \
  --json
```

## Swift SDK

`SwiftTangled` exposes reusable APIs used by the CLI. For example,
`JetstreamClient` provides a reconnecting stream of live AT Protocol events:

```swift
import SwiftTangled

let client = JetstreamClient()
for try await event in client.events(
  options: JetstreamOptions(
    wantedCollections: ["sh.tangled.repo.pull"],
    wantedDIDs: ["did:plc:example"]
  )
) {
  print(event.timeUS, event.kind.rawValue)
}
```

Use authoritative PDS records for current record state, Bobbin for indexed
aggregate reads, Spindle for pipelines, and Jetstream for live events.

## Agent Skill

The repository includes a reusable [`tng` Agent Skill](skills/tng/SKILL.md)
for agents that work with Tangled repositories, issues, pull requests, rounds,
comments, artifacts, and Spindle pipelines.

Point an Agent Skills-compatible tool at the complete `skills/tng` directory,
or copy or symlink it into the tool's skill directory so its workflow reference
remains available.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development environment, testing,
design, and contribution guidelines.

## License

swift-tangled is available under the [MIT License](LICENSE).
