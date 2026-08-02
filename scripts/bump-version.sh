#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${TIMBRE_PROJECT_FILE:-${REPO_ROOT}/Timbre.xcodeproj/project.pbxproj}"

if [[ "$(git -C "${REPO_ROOT}" branch --show-current)" != "main" ]]; then
  echo "Run this release script from the main branch." >&2
  exit 1
fi

if ! git -C "${REPO_ROOT}" diff --quiet || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
  echo "Working tree is not clean; commit or stash existing changes first." >&2
  exit 1
fi

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
release_tag="v${next_version}"

if git -C "${REPO_ROOT}" rev-parse --verify "refs/tags/${release_tag}" >/dev/null 2>&1; then
  echo "Tag already exists locally: ${release_tag}" >&2
  exit 1
fi

if git -C "${REPO_ROOT}" ls-remote --exit-code --tags origin "refs/tags/${release_tag}" >/dev/null 2>&1; then
  echo "Tag already exists on origin: ${release_tag}" >&2
  exit 1
fi

if sed --version >/dev/null 2>&1; then
  sed -i "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${next_version};/g" "${PROJECT_FILE}"
else
  sed -i '' "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${next_version};/g" "${PROJECT_FILE}"
fi

git -C "${REPO_ROOT}" add "${PROJECT_FILE}"
git -C "${REPO_ROOT}" commit -m "Bump version to ${next_version}"
git -C "${REPO_ROOT}" push origin main
git -C "${REPO_ROOT}" tag "${release_tag}"
git -C "${REPO_ROOT}" push origin "${release_tag}"

echo "Released Timbre ${next_version}: ${release_tag}"
