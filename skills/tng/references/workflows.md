# `tng` workflows

Use these workflows as patterns. Inspect command help before execution because
the installed `tng` version is authoritative.

## Inspect a repository or issue

```sh
tng repo view OWNER/REPOSITORY --json
tng issue list OWNER/REPOSITORY --limit 30 --json
tng issue view ISSUE_AT_URI --json
```

Use a DID or handle where the command accepts an owner. Repository arguments
may also use a Tangled repository URL or Git remote form. If an owner/name
reference does not resolve but an authoritative repository AT URI or repo DID
is already available, retry with that identifier; do not scrape the web UI to
discover one. Preserve AT URIs and repo DIDs from JSON output for later
commands. Repository listings come from the owner's PDS. Repository and Issue
record reads prefer the record owner's PDS and use Bobbin only as a fallback
for temporary PDS failures; Issue lists and comments are Bobbin aggregates.

## Create an issue

Verify the target repository, title, and complete body before writing. Prefer a
body file for multiline text:

```sh
tng issue create --repo OWNER/REPOSITORY \
  --title "Describe the problem" \
  --body-file issue.md \
  --json
```

Omit `--repo` only when the current Git `origin` unambiguously identifies the
target Tangled repository. Report the returned Issue URI and CID. A successful
PDS write does not guarantee immediate visibility through Bobbin.

## Discuss an issue

Read the Issue and its first page of comments before responding:

```sh
tng issue view ISSUE_AT_URI --comments --json
```

Follow the returned cursor with `--comment-cursor` when more context is needed.
After verifying the target Issue and complete body, create the comment:

```sh
tng issue comment ISSUE_AT_URI --body-file comment.md --json
```

Report the returned comment URI and CID. Do not include private tracker
identifiers in a public Tangled comment.

## Edit or change the state of an issue

Inspect the current record before editing:

```sh
tng issue view ISSUE_AT_URI --json
tng issue edit ISSUE_AT_URI --title "Updated title" --body-file issue.md --json
```

An edit uses the current CID as a compare-and-swap condition. On conflict, read
the Issue again and do not retry until the user confirms how to reconcile it.
Use an empty `--body` value to remove the body.

After verifying permission and the desired final state:

```sh
tng issue close ISSUE_AT_URI --json
tng issue reopen ISSUE_AT_URI --json
```

State changes create immutable state records. Report their URI and CID.

## Review a pull request

1. Find the pull request when its AT URI is not known. When the author is
   known, use `--author` to read the author's PDS without waiting for Bobbin:

   ```sh
   tng pr list OWNER/REPOSITORY --author AUTHOR_HANDLE --limit 30 --json
   tng pr list OWNER/REPOSITORY --limit 30 --json
   ```

   The author mode reads pull requests from the author PDS and status records
   from the author and repository owner PDSes. It reports an unknown comment
   count as `-1` in JSON and `-` in the table. Without `--author`, the list is a
   Bobbin aggregate and may lag recent PDS writes.

2. Read its rounds and comments:

   ```sh
   tng pr view PULL_AT_URI --comments --comment-limit 30 --json
   ```

3. Inspect the latest round, or the zero-based round requested by the user:

   ```sh
   tng pr diff PULL_AT_URI
   tng pr diff PULL_AT_URI --round 0
   ```

4. Inspect CI using the same repository:

   ```sh
   tng pipeline list OWNER/REPOSITORY --limit 30 --json
   tng pipeline status PIPELINE_ID --repo OWNER/REPOSITORY --json
   ```

   A repository may not expose a Spindle. Report that absence instead of
   treating it as a failed pipeline.

5. Base the review on the unified diff, current comments, and pipeline state.
   Do not treat comments on an older round as automatically applying to the
   latest round.

## Comment on a pull request

Verify the pull request URI, selected round, and complete comment body before
writing. Prefer a body file for multiline text.

```sh
tng pr comment PULL_AT_URI --body "Please add a focused error-path test." --json
tng pr comment PULL_AT_URI --round 0 --body-file review.md --json
```

Omitting `--round` targets the latest round. Supply exactly one of `--body` and
`--body-file`. Report the returned comment URI and CID. A successful write
does not guarantee immediate visibility through Bobbin.

## Close or reopen a pull request

Inspect the Pull Request and verify its AT URI, Web URL, current state, and the
state requested by the user. Treat both commands as authenticated writes:

```sh
tng pr view PULL_AT_URI --json
tng pr close PULL_AT_URI --json
tng pr reopen PULL_AT_URI --json
```

Run only the state-changing command that the user authorized. Each state
change creates an immutable status record. Report its URI, CID, Pull Request
URI, and status. Distinguish that successful PDS write from later Bobbin
indexing and Web UI visibility, and do not retry automatically while those
read surfaces are delayed.

## Merge a pull request

Treat merge as a destructive, explicitly authorized operation. Always run the
read-only check first and inspect its complete JSON result:

```sh
tng pr merge PULL_AT_URI --check --json
```

Merge only when `canMerge` is true. A check can include a dependency stack. If
`pullRequestURIs` contains more than one item, show that scope to the user and
run the following only when the whole stack is authorized:

```sh
tng pr merge PULL_AT_URI --stack --json
```

For a single pull request, omit `--stack`. The command repeats the Knot check
immediately before writing. If it reports that the merge succeeded but status
records failed, report the partial success verbatim and do not retry: the Git
branch may already contain the merged commits.

## Create a pull request

Use Git to verify the source branch is committed and already present on
`origin`. Do not push automatically unless the user requested it.

```sh
git status --short
git branch --show-current
git ls-remote --heads origin refs/heads/FEATURE_BRANCH
tng pr create --base main --head FEATURE_BRANCH \
  --title "Describe the change" \
  --body-file pull-request.md \
  --json
```

Let `--repo` default to Git `origin` unless the user supplied a target. Let
`--base` and `--head` use CLI defaults only when the current repository state
makes those defaults unambiguous.

To create a pull request from a Tangled fork, run the command in the fork's
Git checkout and pass the upstream repository to `--repo`:

```sh
git ls-remote --heads origin refs/heads/FEATURE_BRANCH
tng pr create --repo OWNER/UPSTREAM --base main --head FEATURE_BRANCH \
  --title "Describe the change" \
  --body-file pull-request.md \
  --json
```

Before writing, verify that Git `origin` resolves to the intended source
repository, `--repo` resolves to the intended target, and Tangled declares the
source as a fork of that target. The command verifies the source head on
`origin` and the target base on the target repository's Knot endpoint. It does
not fetch or push. If it reports that the base commit is unavailable locally,
run the exact `git fetch` command it suggests and review the updated history
before retrying.

After creation, preserve the returned Pull Request AT URI and verify that exact
record with `tng pr view PULL_AT_URI --json`. Do not use an unfiltered,
Bobbin-backed `pr list` as the immediate creation check. When checking for an
existing Pull Request by author, use `pr list --author AUTHOR_HANDLE`; an empty
unfiltered result does not prove absence. If creation was interrupted before a
URI was returned, do not retry until PDS state has been checked and the user
explicitly authorizes another write.

## Resubmit a pull request

Inspect the Pull Request and verify its exact AT URI, current status, source
branch, target branch, and rounds. For a branch in the target repository, the
source branch must be committed and already pushed at its current commit:

```sh
tng pr view PULL_AT_URI --json
git status --short
git ls-remote --heads origin refs/heads/FEATURE_BRANCH
tng pr resubmit PULL_AT_URI --json
```

For a fork-based Pull Request, run the command from a checkout whose `origin`
is the Pull Request's source repository:

```sh
tng pr view PULL_AT_URI --json
tng repo view --json
tng pr resubmit PULL_AT_URI --json
```

The command verifies the source repository against Git `origin`, asks the
source Knot to refresh `hidden/SOURCE_BRANCH/TARGET_BRANCH`, and compares that
tracking ref with the source branch on the Knot. It does not generate the fork
patch from local Git state.

For a patch-based Pull Request, prepare a cumulative patch containing the
complete change from the target branch. Both `git diff` and
`git format-patch` are accepted:

```sh
tng pr resubmit PULL_AT_URI --patch-file changes.patch --json
```

`--patch-file` is required for patch-based Pull Requests and rejected for
branch-based and fork-based Pull Requests. The command supports open,
non-stacked Pull Requests that are branch-based, fork-based, or patch-based.
It reports stacked Pull Requests as unsupported instead of applying their
multi-record semantics implicitly.

Report the returned Pull Request URI, CID, and zero-based round number. Verify
the exact record and new round directly rather than assuming Bobbin or the Web
UI has indexed the update:

```sh
tng pr view PULL_AT_URI --json
tng pr diff PULL_AT_URI --round NEW_ROUND
```

Do not retry a CID conflict automatically. Read the current record and let the
user decide whether the new source state should be submitted.

## Paginate JSON results

List operations return a page object with `items` and an optional `cursor`.
Process the first page, then pass its cursor to the same command without
changing filters or sort order:

```sh
tng pr list OWNER/REPOSITORY --limit 30 --json
tng pr list OWNER/REPOSITORY --limit 30 --cursor NEXT_CURSOR --json
```

For pull request comments, use `--comment-cursor`:

```sh
tng pr view PULL_AT_URI --comments --comment-limit 30 \
  --comment-cursor NEXT_CURSOR --json
```

Stop when the cursor is absent, the requested number of records has been
collected, or continuing would exceed the user's intended scope. Detect a
repeated cursor and stop instead of looping.

Treat every cursor as specific to its command, read mode, filters, and sort
order. In particular, `pr list --author` requires a cursor returned by the same
author PDS listing; do not pass it to or from an unfiltered Bobbin listing.

## Publish or retrieve an artifact

Use Git to create and push an annotated tag before publishing. Verify the
repository, tag, local regular file, artifact name, and content type:

```sh
tng artifact upload v1.0.0 dist/myapp --repo OWNER/REPOSITORY \
  --name myapp --content-type application/octet-stream --json
```

The JSON result is wrapped in `schemaVersion` and `result`. Do not retry an
existing artifact with `--force` until ownership and replacement are
authorized; `--force` cannot replace another account's record.

Public reads and verified downloads do not require authentication:

```sh
tng artifact list OWNER/REPOSITORY --json
tng artifact view v1.0.0 --repo OWNER/REPOSITORY --json
tng artifact download v1.0.0 myapp --repo OWNER/REPOSITORY -o ./myapp --json
```

When signed in, `artifact list` merges the account's authoritative PDS records
with Bobbin results and prefers the PDS value for a duplicate record URI.
Preserve its opaque integrated cursor unchanged with the same sort order.

Download refuses existing paths by default. Use `--force` only after verifying
that the destination is the intended regular file. To remove only the artifact
record after explicit authorization:

```sh
tng artifact delete v1.0.0 myapp --repo OWNER/REPOSITORY --yes --json
```

Use Git separately if the tag itself must be changed or removed.

## Handle common failures

- Exit `3`: preserve the API message and distinguish not-found, rate-limit,
  upstream, decoding, and unsupported-operation failures.
- Exit `4`: do not inspect credential storage. Ask for `tng auth login
  <handle>` when the operation requires authentication.
- Exit `5`: report the Git precondition. Do not fetch, push, switch, or rewrite
  state without authorization.
- Exit `64`: run the exact command's `--help`, correct the invocation, and do
  not guess option names.
