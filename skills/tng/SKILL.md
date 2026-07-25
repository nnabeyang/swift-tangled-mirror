---
name: tng
description: Use the tng CLI to inspect Tangled repositories, issues, pull requests, rounds, comments, artifacts, and Spindle pipelines, or to perform authenticated Tangled writes. Use for Tangled development workflows where an agent needs structured JSON, pagination, authentication-aware writes, or a clear boundary between Git operations and Tangled operations.
---

# Use Tangled through `tng`

Use `tng` for Tangled-specific workflows. Continue to use Git for clone, fetch,
push, branch, commit, checkout, and working-tree operations.

## Preflight

1. Run `tng capabilities --json` and use its command, option, access,
   authentication, and platform metadata. For an older `tng` without this
   command, fall back to `tng --version` and the relevant
   `tng <group> <command> --help`. Do not assume an option exists.
2. Run `tng auth status`. Continue without authentication only when every
   requested operation is public and read-only.
3. Resolve ambiguous repository references before acting. Prefer the explicit
   repository supplied by the user; otherwise let commands use the current Git
   `origin` where supported.
4. Prefer `--json` for reads and parse the returned object instead of terminal
   tables. Follow returned cursors when the requested result may span pages.

Read [references/workflows.md](references/workflows.md) before reviewing,
creating, commenting on, or merging a pull request, or when handling pagination and
failures.

## Work Safely

- Treat `repo`, `issue`, `pr`, and `pipeline` reads as current state from
  Bobbin or Spindle. Use Git for local and remote Git state.
- Treat pull request round numbers as zero-based. Inspect the pull request
  before selecting a round; use the latest round unless the user identifies a
  specific round.
- Perform `issue create`, `issue comment`, `issue edit`, `issue close`,
  `issue reopen`, `pr create`, `pr comment`, or `pr merge` only when
  the user's request authorizes that write. Before writing, verify the exact
  repository or pull request, branch or round, title, and body.
- Perform `artifact upload` or `artifact delete` only when the user authorizes
  the write. Verify the repository, annotated tag, artifact name, local file,
  and replacement scope first. Use `--yes` for an authorized noninteractive
  deletion; it deletes the artifact record, not the Git tag.
- Before editing or changing an Issue state, inspect the Issue and verify its
  AT URI. Do not automatically retry an edit rejected because its CID changed;
  read the latest record and ask the user to review conflicting changes.
- Before `pr merge`, run `pr merge PULL_AT_URI --check --json`. If the result
  contains more than one pull request, merge only when the user authorized the
  stack and pass `--stack`. Never retry a merge automatically when the command
  says the Git merge succeeded but status records failed.
- Before creating a pull request from a fork, verify that Git `origin` is the
  intended source, `--repo` is the intended target, and Tangled's fork metadata
  connects them. Keep public test branches, commits, and pull requests free of
  private issue identifiers.
- Do not run `git push`, change branches, edit files, merge, star, or unstar
  merely because they might help a Tangled task. Obtain authorization when
  they are not already part of the request.
- Never read or expose session files, Keychain entries, OAuth tokens, DPoP
  keys, `.env` files, SSH keys, or other credentials. Use `tng auth` commands
  as the authentication interface.
- Do not invent an equivalent when `tng` reports an unsupported operation.
  Explain the missing capability and preserve the original error category.
- Do not use or scrape the Tangled web UI as an API. Use `tng` output.

## Interpret Failures

Use the process exit status as the stable first-level error category:

- `1`: unexpected failure
- `3`: Tangled SDK or API failure
- `4`: authentication or session failure
- `5`: Git failure
- `64`: invalid command usage

When a command supports `--json`, parse the single JSON error object from
standard error. Use `error.category`, `error.code`, and `error.exitCode` for
decisions; treat `error.message` as a human-readable diagnostic. Fall back to
the process status and text diagnostic when using an older installed version.

For status `4`, ask the user to run or complete `tng auth login <handle>` when
interactive authorization is required. For status `5`, report the exact Git
precondition and do not silently fetch, push, or rewrite repository state.

## Report Results

Summarize the resolved repository and record URI, selected round, relevant
pipeline state, and any cursor not consumed. After a write, report the created
record URI and CID returned by `tng`. Distinguish a successful PDS write from
later Bobbin indexing or read-back.
