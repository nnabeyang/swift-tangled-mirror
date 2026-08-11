# Run the CI authentication agent as a service

Keep a restricted Tangled identity available to self-hosted virtual-machine
workers without copying its OAuth session into a guest.

## Create a restricted session

Choose a private absolute path for each CI identity and sign in with the
`ci-reporting` profile:

```sh
TNG_SESSION_FILE="/Users/ci/Library/Application Support/tng/ci-reporting.json" \
  tng auth login CI_HANDLE --profile ci-reporting
```

The session file and its parent directory must be owned by the current user and
inaccessible to group and other users.

## Install the macOS service

Install a named per-user LaunchAgent with explicit session and socket paths:

```sh
tng auth agent service install \
  --session-file "/Users/ci/Library/Application Support/tng/ci-reporting.json" \
  --socket "/Users/ci/Library/Application Support/tng/ci-agent.sock" \
  --profile ci-reporting \
  --instance ci-reporting
```

The service starts immediately. It starts again after an unexpected exit and
when the user logs in after a host restart. FileVault may require an interactive
login before the LaunchAgent can run. The property list contains the session
file path but never its OAuth tokens, refresh token, or DPoP key.

Pass `--executable` during installation when `tng` is not installed at a stable
path. Reinstall the instance after moving the executable.

## Operate and diagnose the service

Use the same instance for every lifecycle command:

```sh
tng auth agent service status --instance ci-reporting
tng auth agent service restart --instance ci-reporting
tng auth agent service stop --instance ci-reporting
tng auth agent service start --instance ci-reporting
tng auth agent service uninstall --instance ci-reporting
```

Add `--json` for structured state. Status distinguishes an uninstalled or
stopped service, an invalid or expired session, an unavailable socket, and an
incompatible protocol. It includes account metadata only after a successful
private-socket probe.

Standard output and error are stored in
`~/Library/Logs/tng/auth-agent/<instance>/stdout.log` and `stderr.log`.
Uninstalling preserves these logs and the session file.

Run one named instance with a distinct session file and socket for each CI
identity. The trusted VM host bridge selects the correct socket and exposes only
`TNG_AUTH_AGENT=vsock://host:10241` inside its guest.

On Linux or when debugging interactively, run the foreground `tng auth agent
serve` command instead of the macOS service commands.
