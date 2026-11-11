#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
if [[ -f "$PROJECT_DIR/scripts/release-config.env" ]]; then
    source "$PROJECT_DIR/scripts/release-config.env"
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: ./scripts/release.sh <version> [release-notes]"
    echo "Example: ./scripts/release.sh 1.0.1 \"Bugfixes and improvements\""
    exit 1
fi

NEW_VERSION="${1#v}"
RELEASE_NOTES="${2:-Feilrettinger og forbedringer i FlowFile ${NEW_VERSION}.}"

export APP_VERSION="$NEW_VERSION"
export BUILD_NUMBER="$(date +%Y%m%d%H%M)"

RELEASE_DIR="$PROJECT_DIR/build/releases/v${NEW_VERSION}"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "[release] Building FlowFile v${NEW_VERSION}..."
"$PROJECT_DIR/scripts/build-installer.sh"

if [[ -f "$PROJECT_DIR/build/installers/FlowFile-${NEW_VERSION}-Installer.dmg" ]]; then
    cp "$PROJECT_DIR/build/installers/FlowFile-${NEW_VERSION}-Installer.dmg" "$RELEASE_DIR/"
fi

echo "[release] Creating FlowFile-Update.zip..."
UPDATE_ZIP="$RELEASE_DIR/FlowFile-Update.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/build/FlowFile.app" "$UPDATE_ZIP"

if [[ -n "${NOTARY_PROFILE:-}" && "${SIGN_IDENTITY:--}" != "-" ]]; then
    echo "[release] Submitting DMG to Apple Notarization..."
    if [[ -f "$RELEASE_DIR/FlowFile-${NEW_VERSION}-Installer.dmg" ]]; then
        xcrun notarytool submit "$RELEASE_DIR/FlowFile-${NEW_VERSION}-Installer.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$RELEASE_DIR/FlowFile-${NEW_VERSION}-Installer.dmg"
    fi
fi

(
    cd "$RELEASE_DIR"
    ARTIFACTS=(FlowFile-Update.zip)
    if [[ -f "FlowFile-${NEW_VERSION}-Installer.dmg" ]]; then
        ARTIFACTS+=("FlowFile-${NEW_VERSION}-Installer.dmg")
    fi
    shasum -a 256 "${ARTIFACTS[@]}" > SHA256SUMS.txt
)

echo "[release] Release artifacts generated in: $RELEASE_DIR"
cat "$RELEASE_DIR/SHA256SUMS.txt"

if [[ -n "${FLOWFILE_REPO:-}" && "${PUBLISH_GITHUB:-1}" == "1" ]]; then
    echo "[release] Publishing v${NEW_VERSION} to GitHub Releases (${FLOWFILE_REPO})..."
    ASSETS=("$RELEASE_DIR/FlowFile-Update.zip" "$RELEASE_DIR/SHA256SUMS.txt")
    if [[ -f "$RELEASE_DIR/FlowFile-${NEW_VERSION}-Installer.dmg" ]]; then
        ASSETS+=("$RELEASE_DIR/FlowFile-${NEW_VERSION}-Installer.dmg")
    fi
    python3 "$PROJECT_DIR/scripts/publish-github-release.py" \
        --repo "$FLOWFILE_REPO" \
        --tag "v${NEW_VERSION}" \
        --title "FlowFile ${NEW_VERSION}" \
        --notes "$RELEASE_NOTES" \
        "${ASSETS[@]}"
fi
