#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/Timbre.xcodeproj"
DERIVED_DATA="${TIMBRE_DERIVED_DATA:-${REPO_ROOT}/.derivedData/FullApplicationIntegration}"
DESTINATION="${TIMBRE_TEST_DESTINATION:-platform=macOS,arch=arm64}"

echo "Building the complete test bundle once..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme Timbre \
  -configuration Debug \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build-for-testing

echo "Running unit tests and the unified full-app UI test without rebuilding..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme Timbre \
  -configuration Debug \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  test-without-building
