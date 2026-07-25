#!/usr/bin/env bash

set -Eeuo pipefail

readonly PRODUCT_NAME="tng"
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
readonly SWIFT_COMMAND="${SWIFT_COMMAND:-swift}"
readonly SWIFTPM_BIN_DIRECTORY="${SWIFTPM_BIN_DIR:-${HOME}/.swiftpm/bin}"
readonly INSTALLED_EXECUTABLE="${SWIFTPM_BIN_DIRECTORY}/${PRODUCT_NAME}"

current_stage="initialization"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

report_error() {
  local exit_status="$1"
  local line_number="$2"
  printf 'error: %s failed at line %s (exit %s)\n' \
    "${current_stage}" "${line_number}" "${exit_status}" >&2
  exit "${exit_status}"
}

stage() {
  current_stage="$2"
  printf '\n[%s/4] %s\n' "$1" "$2"
}

trap 'report_error "$?" "$LINENO"' ERR

cd "${SCRIPT_DIRECTORY}"

stage 1 "Checking prerequisites"
if [[ "${SWIFT_COMMAND}" == */* ]]; then
  [[ -x "${SWIFT_COMMAND}" ]] || fail "Swift executable is not available: ${SWIFT_COMMAND}"
else
  command -v "${SWIFT_COMMAND}" >/dev/null 2>&1 \
    || fail "Swift is not available on PATH"
fi
"${SWIFT_COMMAND}" package experimental-install --help >/dev/null
printf 'Swift: %s\n' "$("${SWIFT_COMMAND}" --version | head -n 1)"

stage 2 "Building ${PRODUCT_NAME} (release)"
"${SWIFT_COMMAND}" build --configuration release --product "${PRODUCT_NAME}"

stage 3 "Installing ${PRODUCT_NAME}"
if [[ -e "${INSTALLED_EXECUTABLE}" ]]; then
  printf 'Removing existing installation: %s\n' "${INSTALLED_EXECUTABLE}"
  "${SWIFT_COMMAND}" package experimental-uninstall "${PRODUCT_NAME}"
else
  printf 'No existing installation found; continuing with a fresh install.\n'
fi
"${SWIFT_COMMAND}" package experimental-install \
  --configuration release \
  --product "${PRODUCT_NAME}"

stage 4 "Verifying installation"
[[ -x "${INSTALLED_EXECUTABLE}" ]] \
  || fail "Installed executable is missing or not executable: ${INSTALLED_EXECUTABLE}"
printf 'Installed: %s\n' "${INSTALLED_EXECUTABLE}"
"${INSTALLED_EXECUTABLE}" --version

case ":${PATH}:" in
  *":${SWIFTPM_BIN_DIRECTORY}:"*) ;;
  *)
    printf '\nAdd SwiftPM executables to PATH, then start a new shell:\n'
    printf '  export PATH="%s:$%s"\n' "${SWIFTPM_BIN_DIRECTORY}" "PATH"
    ;;
esac

printf '\nInstallation complete.\n'
