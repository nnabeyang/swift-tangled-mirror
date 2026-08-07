#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'usage: %s [--check]\n' "$0" >&2
}

if [[ "$#" -gt 1 ]]; then
  usage
  exit 64
fi

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
elif [[ "$#" != 0 ]]; then
  usage
  exit 64
fi

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repository_root

normalize_documentation_for_comparison() {
  local source_directory="$1"
  local destination_directory="$2"

  cp -R "${source_directory}" "${destination_directory}"

  local javascript_directory="${destination_directory}/js"
  if [[ ! -d "${javascript_directory}" ]]; then
    printf 'error: generated documentation JavaScript is missing: %s\n' \
      "${javascript_directory}" >&2
    return 1
  fi

  local index_bundle_count
  index_bundle_count="$(
    find "${javascript_directory}" -maxdepth 1 -type f -name 'index.*.js' -print \
      | wc -l \
      | tr -d '[:space:]'
  )"
  if [[ "${index_bundle_count}" != 1 ]]; then
    printf 'error: expected one DocC index JavaScript bundle in %s; found %s\n' \
      "${javascript_directory}" "${index_bundle_count}" >&2
    return 1
  fi

  local renderer_chunk_count
  renderer_chunk_count="$(
    find "${javascript_directory}" -maxdepth 1 -type f -name '416.*.js' -print \
      | wc -l \
      | tr -d '[:space:]'
  )"
  if [[ "${renderer_chunk_count}" != 1 ]]; then
    printf 'error: expected one DocC renderer chunk in %s; found %s\n' \
      "${javascript_directory}" "${renderer_chunk_count}" >&2
    return 1
  fi

  local documentation_directory="${destination_directory}/documentation"
  if [[ ! -d "${documentation_directory}" ]]; then
    printf 'error: generated documentation routes are missing: %s\n' \
      "${documentation_directory}" >&2
    return 1
  fi

  local route_count=0
  local route_path
  while IFS= read -r -d '' route_path; do
    route_count=$((route_count + 1))

    local index_reference_count
    index_reference_count="$(
      { grep -Eo 'js/index\.[[:xdigit:]]+\.js' "${route_path}" || true; } \
        | wc -l \
        | tr -d '[:space:]'
    )"
    if [[ "${index_reference_count}" != 1 ]]; then
      printf 'error: expected one DocC index JavaScript reference in %s; found %s\n' \
        "${route_path}" "${index_reference_count}" >&2
      return 1
    fi

    sed -E 's#js/index\.[[:xdigit:]]+\.js#js/index.DOCC_PLATFORM.js#g' \
      "${route_path}" >"${route_path}.normalized"
    mv -- "${route_path}.normalized" "${route_path}"
  done < <(find "${documentation_directory}" -type f -name index.html -print0)

  if [[ "${route_count}" == 0 ]]; then
    printf 'error: generated documentation routes are missing from %s\n' \
      "${documentation_directory}" >&2
    return 1
  fi

  find "${javascript_directory}" -maxdepth 1 -type f \
    \( -name 'index.*.js' -o -name '416.*.js' \) -delete
}

# shellcheck source=../documentation.lock
source "${repository_root}/documentation.lock"

swift_version_output="$(swift --version)"
actual_swift_version="$(printf '%s\n' "${swift_version_output}" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
if [[ "${actual_swift_version}" != "${DOCC_SWIFT_VERSION}" ]]; then
  printf 'error: Swift %s is selected; expected Swift %s\n' \
    "${actual_swift_version:-unknown}" "${DOCC_SWIFT_VERSION}" >&2
  exit 1
fi

if command -v docc >/dev/null 2>&1; then
  docc_command=(docc)
elif command -v xcrun >/dev/null 2>&1; then
  docc_command=(xcrun docc)
else
  printf 'error: neither docc nor xcrun is available\n' >&2
  exit 1
fi

if command -v xcodebuild >/dev/null 2>&1; then
  xcode_version_output="$(xcodebuild -version)"
  actual_xcode_version="$(printf '%s\n' "${xcode_version_output}" | sed -n '1s/^Xcode //p')"
  actual_xcode_build="$(printf '%s\n' "${xcode_version_output}" | sed -n '2s/^Build version //p')"
  if [[ "${actual_xcode_version}" != "${DOCC_XCODE_VERSION}" \
    || "${actual_xcode_build}" != "${DOCC_XCODE_BUILD}" ]]; then
    printf 'error: Xcode %s build %s is selected; expected Xcode %s build %s\n' \
      "${actual_xcode_version:-unknown}" "${actual_xcode_build:-unknown}" \
      "${DOCC_XCODE_VERSION}" "${DOCC_XCODE_BUILD}" >&2
    exit 1
  fi
fi

swift build --package-path "${repository_root}" --product tng

bin_directory="$(swift build --package-path "${repository_root}" --show-bin-path)"
readonly bin_directory

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/swift-tangled-documentation.XXXXXX")"
readonly temporary_directory
trap 'rm -rf -- "${temporary_directory}"' EXIT

catalog_path="${temporary_directory}/Tng.docc"
readonly catalog_path
generated_path="${temporary_directory}/generated"
readonly generated_path
output_path="${temporary_directory}/docs"
readonly output_path
committed_comparison_path="${temporary_directory}/committed-docs"
readonly committed_comparison_path
generated_comparison_path="${temporary_directory}/generated-docs"
readonly generated_comparison_path

cp -R "${repository_root}/Documentation/Tng.docc" "${catalog_path}"
swift run --package-path "${repository_root}" ManualSiteGenerator \
  --tool "${bin_directory}/tng" \
  --output "${generated_path}"
cp -R "${generated_path}/catalog/." "${catalog_path}/"

DOCC_JSON_PRETTYPRINT=YES "${docc_command[@]}" convert "${catalog_path}" \
  --output-path "${output_path}" \
  --transform-for-static-hosting \
  --hosting-base-path "${DOCC_HOSTING_BASE_PATH}" \
  --warnings-as-errors \
  --fallback-display-name "${DOCC_BUNDLE_DISPLAY_NAME}" \
  --fallback-bundle-identifier "${DOCC_BUNDLE_IDENTIFIER}" \
  --fallback-default-module-kind "${DOCC_DEFAULT_MODULE_KIND}"

cp "${repository_root}/Documentation/Site/index.html" "${output_path}/index.html"
cp "${repository_root}/Documentation/Site/site.css" "${output_path}/site.css"
cp "${repository_root}/Documentation/Site/og-image.jpg" "${output_path}/og-image.jpg"
find "${output_path}" -depth -type d -empty -delete

if [[ "${check_only}" == true ]]; then
  [[ -d "${repository_root}/docs" ]] \
    || { printf 'error: generated documentation is missing: %s\n' "${repository_root}/docs" >&2; exit 1; }
  normalize_documentation_for_comparison \
    "${repository_root}/docs" "${committed_comparison_path}"
  normalize_documentation_for_comparison \
    "${output_path}" "${generated_comparison_path}"
  if ! diff -ru "${committed_comparison_path}" "${generated_comparison_path}"; then
    printf 'error: generated documentation is out of date\n' >&2
    exit 1
  fi
  printf 'Documentation is up to date.\n'
else
  rm -rf -- "${repository_root}/docs"
  mv -- "${output_path}" "${repository_root}/docs"
  printf 'Generated documentation in %s.\n' "${repository_root}/docs"
fi
