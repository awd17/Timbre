#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${TIMBRE_PROJECT_FILE:-${REPO_ROOT}/Timbre.xcodeproj/project.pbxproj}"

if [[ ! -f "${PROJECT_FILE}" ]]; then
  echo "Project file not found: ${PROJECT_FILE}" >&2
  exit 1
fi

version_line_count="$(awk '/MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;/ { count++ } END { print count + 0 }' "${PROJECT_FILE}")"
if [[ "${version_line_count}" != "2" ]]; then
  echo "Expected exactly two three-part app version entries; found ${version_line_count}." >&2
  exit 1
fi

current_version="$(awk '
  /MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;/ {
    version = $3
    sub(/;/, "", version)
    print version
    exit
  }
' "${PROJECT_FILE}")"

IFS=. read -r major minor patch <<< "${current_version}"
next_version="${major}.${minor}.$((patch + 1))"

if sed --version >/dev/null 2>&1; then
  sed -i "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${next_version};/g" "${PROJECT_FILE}"
else
  sed -i '' "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${next_version};/g" "${PROJECT_FILE}"
fi

echo "Bumped Timbre version: ${current_version} -> ${next_version}"
echo "Next release tag: v${next_version}"
