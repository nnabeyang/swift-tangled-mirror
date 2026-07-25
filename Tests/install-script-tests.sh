#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
TEMPORARY_DIRECTORY="$(mktemp -d)"
readonly TEMPORARY_DIRECTORY
readonly TEST_HOME="${TEMPORARY_DIRECTORY}/home"
readonly MOCK_SWIFT="${TEMPORARY_DIRECTORY}/swift"
readonly COMMAND_LOG="${TEMPORARY_DIRECTORY}/commands.log"
export COMMAND_LOG

cleanup() {
  rm -rf "${TEMPORARY_DIRECTORY}"
}
trap cleanup EXIT

mkdir -p "${TEST_HOME}"

cat >"${MOCK_SWIFT}" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >>"${COMMAND_LOG}"

if [[ "$*" == "--version" ]]; then
  printf 'Swift version test\n'
elif [[ "$*" == "package experimental-uninstall tng" ]]; then
  rm -f "${HOME}/.swiftpm/bin/tng"
elif [[ "$*" == "package experimental-install --configuration release --product tng" ]]; then
  mkdir -p "${HOME}/.swiftpm/bin"
  cat >"${HOME}/.swiftpm/bin/tng" <<'TNG'
#!/usr/bin/env bash
printf '0.1.0-test\n'
TNG
  chmod +x "${HOME}/.swiftpm/bin/tng"
fi
MOCK
chmod +x "${MOCK_SWIFT}"

run_installer() {
  HOME="${TEST_HOME}" \
  SWIFT_COMMAND="${MOCK_SWIFT}" \
  PATH="/usr/bin:/bin" \
    "${REPOSITORY_ROOT}/install.sh"
}

bash -n "${REPOSITORY_ROOT}/install.sh"

first_output="$(run_installer)"
second_output="$(run_installer)"

grep -Fq "[1/4] Checking prerequisites" <<<"${first_output}"
grep -Fq "[2/4] Building tng (release)" <<<"${first_output}"
grep -Fq "No existing installation found" <<<"${first_output}"
grep -Fq "Installation complete." <<<"${first_output}"
grep -Fq "0.1.0-test" <<<"${first_output}"
grep -Fq "Removing existing installation" <<<"${second_output}"
grep -Fq "[4/4] Verifying installation" <<<"${second_output}"
grep -Fq "0.1.0-test" <<<"${second_output}"

[[ "$(grep -Fc "build --configuration release --product tng" "${COMMAND_LOG}")" == 2 ]]
[[ "$(grep -Fc "package experimental-uninstall tng" "${COMMAND_LOG}")" == 1 ]]
[[ "$(grep -Fc "package experimental-install --configuration release --product tng" \
  "${COMMAND_LOG}")" == 2 ]]

printf 'install.sh tests passed\n'
