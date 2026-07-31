#!/usr/bin/env bash
# Reset Timbre to a completely fresh first-run state.
#
# Clears: Clerk OAuth keychain credentials, onboarding + user prefs,
# CoreML compiled-model cache, and system Microphone / Accessibility
# permissions. Also deletes the downloaded Parakeet model cache when
# invoked with --delete-model.
#
# Usage:
#   scripts/reset-fresh-user.sh                  # keep downloaded model
#   scripts/reset-fresh-user.sh --delete-model   # also wipe model cache
#   scripts/reset-fresh-user.sh --release        # target the Release bundle id
#
# Defaults to the Debug build (com.augustdrakton.Timbre.debug).
# Quit Timbre before running. Rebuild in Xcode afterward.

set -euo pipefail

BUNDLE_ID="com.augustdrakton.Timbre.debug"
DELETE_MODEL=0

for arg in "$@"; do
  case "$arg" in
    --delete-model) DELETE_MODEL=1 ;;
    --release) BUNDLE_ID="com.augustdrakton.Timbre" ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "usage: $0 [--delete-model] [--release]" >&2
      exit 2
      ;;
  esac
done

KEYCHAIN_SERVICE="com.augustdrakton.Timbre.oauth"
KEYCHAIN_ACCOUNT="clerk-oauth-credentials"
SUPPORT_DIR="$HOME/Library/Application Support/FluidAudio/Models"
MODEL_DIR="$SUPPORT_DIR/parakeet-tdt-0.6b-v2"
APP_CACHE_DIR="$HOME/Library/Caches/$BUNDLE_ID"

echo "Resetting Timbre as a fresh user"
echo "  bundle id : $BUNDLE_ID"
echo "  model dir : $MODEL_DIR"
echo "  delete model: $([ "$DELETE_MODEL" -eq 1 ] && echo yes || echo no)"
echo

# 1. Clerk OAuth credentials from the login keychain.
echo "→ Keychain OAuth credentials ($KEYCHAIN_SERVICE)"
if security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null; then
  echo "  removed"
else
  echo "  nothing to remove"
fi

# 2. Onboarding + user preferences stored in UserDefaults.
echo "→ UserDefaults (onboarding, shortcut, prefs)"
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "  removed" || echo "  nothing to remove"

# 3. Core ML compiled-model cache for this app.
echo "→ CoreML app cache ($APP_CACHE_DIR)"
rm -rf "$APP_CACHE_DIR" && echo "  removed" || echo "  skipped"

# 4. Downloaded Parakeet model (only when --delete-model is passed).
if [ "$DELETE_MODEL" -eq 1 ]; then
  echo "→ Parakeet model cache"
  if [ -d "$MODEL_DIR" ]; then
    rm -rf "$MODEL_DIR"
    echo "  removed $MODEL_DIR"
  else
    echo "  nothing to remove"
  fi
  rmdir "$SUPPORT_DIR" 2>/dev/null || true
fi

# 5. System TCC permissions (Microphone, Accessibility).
# tccutil exits non-zero if the entry is missing; tolerate that.
echo "→ TCC permissions"
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null && echo "  microphone reset" || echo "  microphone: nothing to reset"
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null && echo "  accessibility reset" || echo "  accessibility: nothing to reset"

echo
echo "Reset complete. Clean + rebuild Timbre in Xcode, then launch to verify the first-run flow."