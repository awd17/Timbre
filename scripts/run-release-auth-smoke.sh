#!/usr/bin/env bash
set -euo pipefail

# Keep BSD shasum/hdiutil portable on machines whose shell advertises a locale
# that is not installed in the command-line tool environment.
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/Timbre.xcodeproj"
DERIVED_DATA="${TIMBRE_RELEASE_SMOKE_DERIVED_DATA:-${REPO_ROOT}/.derivedData/ReleaseAuthSmoke}"
API_BASE_URL="${TIMBRE_RELEASE_SMOKE_API_BASE_URL:-http://127.0.0.1:3000}"
PACKAGE_DIR="${DERIVED_DATA}/release"
DMG_ROOT="${DERIVED_DATA}/dmg-root"
LAUNCH=0
FRESH=0

usage() {
    cat <<'EOF'
Usage: scripts/run-release-auth-smoke.sh [options]

Build and package the ad-hoc-signed Release app locally, then validate the
bundle configuration. This exercises the same app shape used by the GitHub
release workflow without creating a GitHub release.

Options:
  --api-base-url URL  API base embedded in the smoke-test app
  --launch            Open the packaged Release app after validation
  --fresh             Reset Release-bundle credentials/preferences before launch
  -h, --help          Show this help

Defaults to http://127.0.0.1:3000 so a local timbre-web checkout can be tested.
Set TIMBRE_RELEASE_SMOKE_API_BASE_URL=https://www.timbre.website/ to test the
currently deployed API with credentials already stored for the Release bundle.
EOF
}

while (($# > 0)); do
    case "$1" in
        --api-base-url)
            if (($# < 2)); then
                echo "error: --api-base-url needs a URL" >&2
                exit 2
            fi
            API_BASE_URL="$2"
            shift 2
            ;;
        --launch)
            LAUNCH=1
            shift
            ;;
        --fresh)
            FRESH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ((FRESH)); then
    if [[ ! -t 0 ]]; then
        echo "error: --fresh requires an interactive terminal" >&2
        exit 2
    fi
    echo "This removes Timbre's Release-bundle OAuth item, preferences, and TCC entries."
    read -r -p "Continue with a fresh-user reset? [y/N] " confirmation
    if [[ "$confirmation" != [yY] ]]; then
        echo "Fresh-user reset cancelled."
        exit 0
    fi
    "${SCRIPT_DIR}/reset-fresh-user.sh" --release
fi

echo "Building Release auth smoke app"
echo "  API base    : ${API_BASE_URL}"
echo "  Derived data: ${DERIVED_DATA}"

xcodebuild \
    -project "${PROJECT}" \
    -scheme Timbre \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    "TIMBRE_API_BASE_URL=${API_BASE_URL}" \
    build

APP_PATH="${DERIVED_DATA}/Build/Products/Release/Timbre.app"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: Release app was not produced at ${APP_PATH}" >&2
    exit 1
fi

# Match the GitHub release workflow's ad-hoc signing step.
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "${APP_PATH}/Contents/Info.plist")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${APP_PATH}/Contents/Info.plist")"
EMBEDDED_API_BASE_URL="$(plutil -extract TIMBRE_API_BASE_URL raw -o - "${APP_PATH}/Contents/Info.plist")"

[[ "${BUNDLE_ID}" == "com.augustdrakton.Timbre" ]] || {
    echo "error: unexpected Release bundle ID: ${BUNDLE_ID}" >&2
    exit 1
}
[[ "${EMBEDDED_API_BASE_URL}" == "${API_BASE_URL}" ]] || {
    echo "error: embedded API base is ${EMBEDDED_API_BASE_URL}, expected ${API_BASE_URL}" >&2
    exit 1
}

rm -rf "${DMG_ROOT}/Timbre.app"
rm -f "${DMG_ROOT}/Applications" "${PACKAGE_DIR}/Timbre.dmg" "${PACKAGE_DIR}/Timbre.dmg.sha256"
mkdir -p "${PACKAGE_DIR}" "${DMG_ROOT}"
ditto "${APP_PATH}" "${DMG_ROOT}/Timbre.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create \
    -volname "Timbre" \
    -srcfolder "${DMG_ROOT}" \
    -ov \
    -format UDZO \
    "${PACKAGE_DIR}/Timbre.dmg" >/dev/null
shasum -a 256 "${PACKAGE_DIR}/Timbre.dmg" > "${PACKAGE_DIR}/Timbre.dmg.sha256"

echo "PASS: Release auth smoke artifact is ready"
echo "  version: ${VERSION}"
echo "  app    : ${APP_PATH}"
echo "  DMG    : ${PACKAGE_DIR}/Timbre.dmg"
echo "  SHA256 : ${PACKAGE_DIR}/Timbre.dmg.sha256"

if ((LAUNCH)); then
    open -n "${APP_PATH}"
fi
