#!/usr/bin/env bash
# One-time prerequisite check + project regeneration.
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Checking prerequisites..."

# 1. Xcode (not just CLI tools)
if ! xcode-select -p >/dev/null 2>&1; then
  echo "ERROR: Xcode is not installed or xcode-select points at nothing."
  echo "  Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
XCODE_DEV="$(xcode-select -p)"
if [[ "$XCODE_DEV" != *"/Xcode.app/"* ]]; then
  echo "ERROR: xcode-select points at '$XCODE_DEV', which is the CLI-tools-only path."
  echo "  Install full Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
echo "  ok   - $(xcodebuild -version | head -1)"

# 2. xcodegen — preferred; project.pbxproj is checked in as fallback
if command -v xcodegen >/dev/null 2>&1; then
  echo "  ok   - xcodegen $(xcodegen --version 2>&1 | head -1)"
  echo "Regenerating Xcode project from project.yml..."
  # xcodegen wipes xcshareddata/ on regenerate, which would delete our
  # hand-written scheme carrying the GPX location-simulation wiring.
  # Stash it across the generate, then restore.
  SCHEME_SRC="GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme"
  SCHEME_STASH=""
  if [[ -f "$SCHEME_SRC" ]]; then
    SCHEME_STASH="$(mktemp -t gpsspoof-scheme).xcscheme"
    cp "$SCHEME_SRC" "$SCHEME_STASH"
  fi
  ( cd GPSSpoof && TEAM_ID="${TEAM_ID:-}" xcodegen generate )
  if [[ -n "$SCHEME_STASH" ]]; then
    mkdir -p "$(dirname "$SCHEME_SRC")"
    mv "$SCHEME_STASH" "$SCHEME_SRC"
  fi
  echo "  ok   - project regenerated"
else
  echo "  warn - xcodegen not installed; using committed project.pbxproj"
  echo "         install with: brew install xcodegen"
fi

# 3. TEAM_ID hint
if [[ -z "${TEAM_ID:-}" ]]; then
  echo ""
  echo "TEAM_ID is not set."
  echo "  Find your team id:"
  echo "    1. Open Xcode > Settings > Accounts, add your Apple ID (free works)."
  echo "    2. Open GPSSpoof/GPSSpoof.xcodeproj > Signing & Capabilities."
  echo "       Pick your Team. Xcode shows the 10-char team id in the dropdown."
  echo "    3. export TEAM_ID=XXXXXXXXXX"
  echo "  Or just open the project once in Xcode and let it auto-sign; spoof.sh will then work without TEAM_ID."
else
  echo "  ok   - TEAM_ID=$TEAM_ID"
fi

echo ""
echo "Setup complete. Next:"
echo "  ./spoof.sh --lat 37.3861 --lon -122.0839 --name 'Mountain View'"
