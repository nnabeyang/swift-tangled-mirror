# Getting started

Install `tng`, sign in when a write operation requires authentication, and
inspect a repository.

## Installation

On an Apple Silicon Mac running macOS 15 or later, install the prebuilt binary
from the Tangled-hosted Homebrew tap:

```sh
brew tap nnabeyang/tap \
  https://tangled.org/nnabeyang.tngl.sh/homebrew-tap
brew install nnabeyang/tap/tng
```

To build and install from source on macOS or Linux, clone the repository and
run `./install.sh` from its root.

## Quick start

```sh
tng --version
tng auth login YOUR_ATPROTO_HANDLE
tng auth status
tng repo view OWNER/REPOSITORY
```

Public read commands do not require authentication. Commands that create or
change Tangled records use your AT Protocol OAuth session.

`tng` keeps OAuth sessions per DID. Inspect the available accounts, select the
default, or override it for a single command:

```sh
tng auth list
tng auth switch HANDLE_OR_DID
tng --account HANDLE_OR_DID issue list --repo OWNER/REPOSITORY
```

Use `tng auth logout` to remove the selected account and `tng auth logout
--all` to remove every stored account. External `TNG_AUTH_AGENT` and
`TNG_SESSION_FILE` authentication bypasses this registry and cannot be combined
with `--account`.

## Finding help

```sh
tng --help
tng repo --help
tng pr create --help
tng capabilities --json
```

Most repository-aware commands infer the repository from the current Git
`origin`. Pass `--repo OWNER/REPOSITORY` when you need to target another
repository explicitly.
