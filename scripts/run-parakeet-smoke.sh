#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE="${REPO_ROOT}/Tools/ParakeetSmokeTest/Fixtures/parakeet-smoke-test.wav"
SCHEME="ParakeetSmokeTest"
PROJECT="${REPO_ROOT}/Timbre.xcodeproj"
DERIVED_DATA="${REPO_ROOT}/.derivedData/ParakeetSmokeTest"

if [[ ! -f "${FIXTURE}" ]]; then
  echo "error: fixture not found at ${FIXTURE}" >&2
  exit 3
fi

# FIXTURE is always absolute (derived from REPO_ROOT / pwd), so no path check needed.

echo "Repository root: ${REPO_ROOT}"
echo "Fixture: ${FIXTURE}"
echo "Building ${SCHEME}..."

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  -configuration Debug \
  build

PRODUCT_DIR="$(
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*TARGET_BUILD_DIR[[:space:]]*=/ { print $2; exit }'
)"

EXECUTABLE="${PRODUCT_DIR}/ParakeetSmokeTest"

if [[ ! -x "${EXECUTABLE}" ]]; then
  # Fallback search under DerivedData
  EXECUTABLE="$(
    find "${DERIVED_DATA}" -type f -name ParakeetSmokeTest -perm -111 2>/dev/null | head -n 1
  )"
fi

if [[ -z "${EXECUTABLE}" || ! -x "${EXECUTABLE}" ]]; then
  echo "error: could not locate ParakeetSmokeTest executable after build" >&2
  exit 1
fi

echo "Executable: ${EXECUTABLE}"
echo "Running smoke test..."
exec "${EXECUTABLE}" --audio "${FIXTURE}"
