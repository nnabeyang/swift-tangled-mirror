#!/usr/bin/env bash

set -Eeuo pipefail

readonly PRODUCT_NAME="tng"
readonly TARGET_TRIPLE="arm64-apple-macosx15.0"
readonly MAXIMUM_ARTIFACT_BYTES=$((50 * 1024 * 1024))

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 ]] || fail "usage: $0 VERSION"

readonly VERSION="$1"
REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT
readonly TAG="${VERSION}"
readonly ARTIFACT_NAME="${PRODUCT_NAME}-${VERSION}-macos-arm64.tar.gz"
readonly OUTPUT_DIRECTORY="${REPOSITORY_ROOT}/.build/releases/${VERSION}"
readonly ARTIFACT_PATH="${OUTPUT_DIRECTORY}/${ARTIFACT_NAME}"
readonly CHECKSUM_PATH="${ARTIFACT_PATH}.sha256"

command -v git >/dev/null 2>&1 || fail "git is not available on PATH"
command -v swift >/dev/null 2>&1 || fail "swift is not available on PATH"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is not available on PATH"
command -v codesign >/dev/null 2>&1 || fail "codesign is not available on PATH"

cd "${REPOSITORY_ROOT}"

[[ "$(git cat-file -t "${TAG}" 2>/dev/null || true)" == "tag" ]] \
  || fail "tag ${TAG} is missing or is not annotated"

TAG_COMMIT="$(git rev-parse "${TAG}^{commit}")"
readonly TAG_COMMIT
TEMPORARY_DIRECTORY="$(mktemp -d)"
readonly TEMPORARY_DIRECTORY
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT

readonly SOURCE_DIRECTORY="${TEMPORARY_DIRECTORY}/source"
readonly STAGING_DIRECTORY="${TEMPORARY_DIRECTORY}/staging"
readonly SCRATCH_DIRECTORY="${TEMPORARY_DIRECTORY}/build"

mkdir -p "${SOURCE_DIRECTORY}" "${STAGING_DIRECTORY}" "${OUTPUT_DIRECTORY}"
git archive "${TAG_COMMIT}" | tar -xf - -C "${SOURCE_DIRECTORY}"

swift build \
  --package-path "${SOURCE_DIRECTORY}" \
  --scratch-path "${SCRATCH_DIRECTORY}" \
  --configuration release \
  --product "${PRODUCT_NAME}" \
  --triple "${TARGET_TRIPLE}"

readonly BUILT_EXECUTABLE="${SCRATCH_DIRECTORY}/arm64-apple-macosx/release/${PRODUCT_NAME}"
[[ -x "${BUILT_EXECUTABLE}" ]] \
  || fail "release executable was not produced: ${BUILT_EXECUTABLE}"

cp "${BUILT_EXECUTABLE}" "${STAGING_DIRECTORY}/${PRODUCT_NAME}"
xcrun strip -S "${STAGING_DIRECTORY}/${PRODUCT_NAME}"
codesign --force --sign - "${STAGING_DIRECTORY}/${PRODUCT_NAME}"

file "${STAGING_DIRECTORY}/${PRODUCT_NAME}" | grep -q "Mach-O 64-bit executable arm64" \
  || fail "release executable is not a Mach-O arm64 binary"
xcrun vtool -show-build "${STAGING_DIRECTORY}/${PRODUCT_NAME}" \
  | grep -Eq 'minos 15(\.0+)?$' \
  || fail "release executable does not target macOS 15"
codesign --verify --strict "${STAGING_DIRECTORY}/${PRODUCT_NAME}"

BUILT_VERSION="$("${STAGING_DIRECTORY}/${PRODUCT_NAME}" --version)"
readonly BUILT_VERSION
[[ "${BUILT_VERSION}" == "${VERSION}" ]] \
  || fail "release version ${BUILT_VERSION} does not match tag ${VERSION}"

cp "${SOURCE_DIRECTORY}/LICENSE" "${STAGING_DIRECTORY}/LICENSE"
COPYFILE_DISABLE=1 tar -czf "${ARTIFACT_PATH}" \
  -C "${STAGING_DIRECTORY}" \
  "${PRODUCT_NAME}" \
  LICENSE

ARTIFACT_BYTES="$(stat -f '%z' "${ARTIFACT_PATH}")"
readonly ARTIFACT_BYTES
((ARTIFACT_BYTES <= MAXIMUM_ARTIFACT_BYTES)) \
  || fail "artifact is larger than 50 MiB: ${ARTIFACT_BYTES} bytes"

(
  cd "${OUTPUT_DIRECTORY}"
  shasum -a 256 "${ARTIFACT_NAME}" >"${ARTIFACT_NAME}.sha256"
)

printf 'Tag commit: %s\n' "${TAG_COMMIT}"
printf 'Artifact: %s\n' "${ARTIFACT_PATH}"
printf 'Checksum: %s\n' "${CHECKSUM_PATH}"
printf 'Bytes: %s\n' "${ARTIFACT_BYTES}"
