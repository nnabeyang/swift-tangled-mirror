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

New logins use an OAuth loopback client and appear on the authorization page as
an application on your device. Use `--client-id` or `TNG_CLIENT_ID` only when an
authorization server requires hosted client metadata. See
the following section for precedence, compatibility, and self-hosting details.

## OAuth client configuration

`tng auth login` binds its callback server to an available local port and then
builds a native client ID containing that exact redirect URI and the requested
scope set. It does not fetch a hosted `client-metadata.json` document.

Authorization server support for loopback client IDs is optional. `tng` does
not silently change clients if the server rejects one. Select hosted metadata
explicitly instead:

```sh
tng auth login YOUR_ATPROTO_HANDLE \
  --client-id https://example.com/tng-client-metadata.json
```

You can also set the choice for one or more login commands:

```sh
TNG_CLIENT_ID=https://example.com/tng-client-metadata.json \
  tng auth login YOUR_ATPROTO_HANDLE
```

The `--client-id` option takes precedence over `TNG_CLIENT_ID`; otherwise the
default is `loopback`. Both settings are read only when signing in. Each session
stores its selected client ID, so refresh, authenticated requests, and logout
continue to use the same client. Sessions created by older `tng` versions keep
using the legacy hosted client ID without migration.

### Host client metadata

Publish a JSON document like the following at the exact HTTPS URL used as
`client_id`. Replace the example URL with your public URL wherever it appears.
The scope value matches the normal `tng` authentication profile.

```json
{
  "client_id": "https://example.com/tng-client-metadata.json",
  "application_type": "native",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "redirect_uris": ["http://127.0.0.1/callback"],
  "scope": "atproto repo:sh.tangled.actor.profile repo:sh.tangled.feed.comment repo:sh.tangled.feed.reaction repo:sh.tangled.feed.star repo:sh.tangled.graph.follow repo:sh.tangled.graph.vouch repo:sh.tangled.knot repo:sh.tangled.knot.member repo:sh.tangled.label.definition repo:sh.tangled.label.op repo:sh.tangled.publicKey repo:sh.tangled.repo repo:sh.tangled.repo.artifact repo:sh.tangled.repo.collaborator repo:sh.tangled.repo.issue repo:sh.tangled.repo.issue.comment repo:sh.tangled.repo.issue.state repo:sh.tangled.repo.pull repo:sh.tangled.repo.pull.comment repo:sh.tangled.repo.pull.status repo:sh.tangled.spindle repo:sh.tangled.spindle.member repo:sh.tangled.string blob:*/* rpc:sh.tangled.knot.addMember?aud=* rpc:sh.tangled.knot.removeMember?aud=* rpc:sh.tangled.ci.triggerPipeline?aud=* rpc:sh.tangled.ci.cancelPipeline?aud=* rpc:sh.tangled.repo.addCollaborator?aud=* rpc:sh.tangled.repo.addSecret?aud=* rpc:sh.tangled.repo.create?aud=* rpc:sh.tangled.repo.delete?aud=* rpc:sh.tangled.repo.deleteBranch?aud=* rpc:sh.tangled.repo.forkStatus?aud=* rpc:sh.tangled.repo.forkSync?aud=* rpc:sh.tangled.repo.hiddenRef?aud=* rpc:sh.tangled.repo.listSecrets?aud=* rpc:sh.tangled.repo.merge?aud=* rpc:sh.tangled.repo.mergeCheck?aud=* rpc:sh.tangled.repo.removeCollaborator?aud=* rpc:sh.tangled.repo.removeSecret?aud=* rpc:sh.tangled.repo.setDefaultBranch?aud=* rpc:sh.tangled.repo.push?aud=* identity:handle",
  "dpop_bound_access_tokens": true,
  "token_endpoint_auth_method": "none"
}
```

The endpoint must return HTTP 200 with `Content-Type: application/json`. Its
`client_id` field must exactly match the HTTPS document URL. Keep the document
available for new authorizations; saved sessions retain the selected client ID
for later refresh and revocation requests.

The metadata lists the loopback callback without a port. `tng` includes the
actual bound port in each authorization request, and authorization servers match
native loopback redirects by host and path while allowing that dynamic port.

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
