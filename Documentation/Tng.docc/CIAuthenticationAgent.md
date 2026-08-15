# Run the CI authentication agent as a service

Keep a restricted Tangled identity available to self-hosted virtual-machine
workers without copying its OAuth tokens into a guest. The agent supports a
native `tng` OAuth session or a session issued through an enrolled token-
mediating backend (TMB). Configure exactly one source for each service.

## Enroll and sign in through a TMB

Obtain a one-time enrollment credential from the TMB administrator and transfer
it over a protected channel. On the Mac that runs `tng`, pass the credential on
standard input without placing it in a command argument:

```sh
read -rs TMB_ENROLLMENT
printf '%s' "$TMB_ENROLLMENT" | tng auth agent tmb enroll \
  --origin https://tmb.example \
  --name ci-worker \
  --instance ci-reporting
unset TMB_ENROLLMENT
```

Delete every transferred copy after enrollment succeeds. The named instance is
stored below `~/Library/Application Support/tng/tmb/ci-reporting`; its directory
and files must remain accessible only to their owner.

Authorize the Tangled account in a browser, then verify a direct authenticated
request to its PDS:

```sh
tng auth agent tmb login CI_HANDLE --instance ci-reporting
tng auth agent tmb status --instance ci-reporting
tng auth agent tmb verify --refresh --instance ci-reporting
```

The TMB participates in authorization and refresh. Normal XRPC requests go
directly from `tng` to the account's PDS with DPoP. The stored access token,
refresh proof, and DPoP private key never belong in a VM image, job environment,
log, or LaunchAgent property list.

## Install the macOS service

Install a named per-user LaunchAgent that opens a private Unix socket and uses
the same TMB instance:

```sh
tng auth agent service install \
  --tmb-instance ci-reporting \
  --socket "/Users/ci/Library/Application Support/tng/ci-agent.sock" \
  --profile ci-reporting \
  --instance ci-reporting
```

The service starts immediately. It starts again after an unexpected exit and
when the user logs in after a host restart. FileVault may require an interactive
login before a per-user LaunchAgent can run. Pass `--executable` during
installation when `tng` is not installed at a stable path, and reinstall after
moving the executable.

For a native OAuth session instead, sign in at a private absolute path and use
`--session-file` in place of `--tmb-instance`:

```sh
TNG_SESSION_FILE="/Users/ci/Library/Application Support/tng/ci-reporting.json" \
  tng auth login CI_HANDLE --profile ci-reporting
tng auth agent service install \
  --session-file "/Users/ci/Library/Application Support/tng/ci-reporting.json" \
  --socket "/Users/ci/Library/Application Support/tng/ci-agent.sock" \
  --profile ci-reporting \
  --instance ci-reporting
```

Do not combine `--session-file` and `--tmb-instance`. A TMB instance must match
the service instance when both names are written explicitly.

## Operate and diagnose the service

Use the same instance for every lifecycle command:

```sh
tng auth agent service status --instance ci-reporting
tng auth agent service restart --instance ci-reporting
tng auth agent service stop --instance ci-reporting
tng auth agent service start --instance ci-reporting
tng auth agent service uninstall --instance ci-reporting
```

Add `--json` for structured state. Status reports whether the authentication
source is `native` or `tmb` and distinguishes an uninstalled or stopped service,
an invalid or expired session, an unavailable socket, and an incompatible
protocol. Account metadata appears only after a successful private-socket probe.
Standard output and error are stored in
`~/Library/Logs/tng/auth-agent/<instance>/stdout.log` and `stderr.log`.
Uninstalling preserves these logs and the authentication state.

If TMB verification fails, stop the service before replacing local state. Check
the public TMB health endpoint and the named instance with `tmb status`; then
repeat `tmb login` if only the OAuth session is absent or revoked. Use `tmb
logout` to revoke one session and keep the device enrollment. Use `tmb revoke
--yes` only when retiring or replacing the device, because it revokes every
session owned by that device and removes both device and session state.

If remote logout cannot complete because the authorization server can no
longer be discovered, stop the auth-agent first and explicitly discard only
the unusable local session:

```sh
tng auth agent tmb logout --instance ci-reporting --local-only --yes
```

This recovery operation does not revoke the remote session. Use it only for a
session that can no longer authenticate, then run `tmb login` again. A running
auth-agent and an interactive command may share one instance: each request
reloads externally rotated state, and conditional replacement prevents a stale
process from overwriting a newer refresh or PDS nonce.

Run one named instance with a distinct authentication source and socket for each
CI identity. The trusted VM host bridge selects that socket and exposes only
`TNG_AUTH_AGENT=vsock://host:10241` inside its guest. The agent binds each
connection to one job, repository DID, deadline, byte quota, and operation
allowlist. The guest never receives the host's OAuth or TMB state.

On Linux or when debugging interactively, run `tng auth agent serve` with
`--tmb-instance ci-reporting`, or set `TNG_SESSION_FILE` for a native session,
instead of using the macOS service commands.
