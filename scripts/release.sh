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
if [[ $# -ge 2 && -n "${2}" ]]; then
    RELEASE_NOTES="${2}"
elif [[ -f "$PROJECT_DIR/scripts/extract-release-notes.py" && -f "$PROJECT_DIR/CHANGELOG.md" ]]; then
    RELEASE_NOTES="$(python3 "$PROJECT_DIR/scripts/extract-release-notes.py" "$PROJECT_DIR/CHANGELOG.md" "$NEW_VERSION")"
else
    RELEASE_NOTES="Feilrettinger og forbedringer i FlowFile ${NEW_VERSION}."
fi

export APP_VERSION="$NEW_VERSION"
export BUILD_NUMBER="$(date +%Y%m%d%H%M)"

RELEASE_DIR="$PROJECT_DIR/build/releases/v${NEW_VERSION}"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

UPDATE_ZIP="$RELEASE_DIR/FlowFile-Update.zip"
DMG_RELEASE="$RELEASE_DIR/FlowFile-${NEW_VERSION}-Installer.dmg"

NOTARY_AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    NOTARY_AUTH_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

if [[ "${SIGN_IDENTITY:--}" != "-" && ${#NOTARY_AUTH_ARGS[@]} -gt 0 ]]; then
    echo "[release] Building & Developer ID signing FlowFile v${NEW_VERSION}..."
    "$PROJECT_DIR/scripts/build-app.sh" release

    APP_BUNDLE="$PROJECT_DIR/build/FlowFile.app"
    NOTARY_APP_ZIP="$RELEASE_DIR/.FlowFile-Notary-Upload.zip"
    rm -f "$NOTARY_APP_ZIP"

    echo "[release] Submitting FlowFile.app to Apple Notarization..."
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARY_APP_ZIP"
    xcrun notarytool submit "$NOTARY_APP_ZIP" "${NOTARY_AUTH_ARGS[@]}" --wait
    rm -f "$NOTARY_APP_ZIP"

    echo "[release] Stapling notarization ticket to FlowFile.app..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    echo "[release] Creating notarized & stapled FlowFile-Update.zip..."
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$UPDATE_ZIP"

    if [[ "${SKIP_DMG:-0}" != "1" ]]; then
        echo "[release] Creating APFS DMG from stapled FlowFile.app..."
        DMG_STAGE_ROOT="/tmp/flowfile-release-dmg-$$"
        DMG_STAGE="$DMG_STAGE_ROOT/dmg"
        rm -rf "$DMG_STAGE_ROOT"
        mkdir -p "$DMG_STAGE" "$PROJECT_DIR/build/installers"
        ditto "$APP_BUNDLE" "$DMG_STAGE/FlowFile.app"
        ln -s /Applications "$DMG_STAGE/Applications"
        cat > "$DMG_STAGE/README - Installasjon.txt" <<EOF
FlowFile ${NEW_VERSION} for macOS
=================================

1. Dra «FlowFile.app» over på «Applications»-mappen.
2. Åpne FlowFile fra Programmer (Applications) eller Spotlight.

All kildekode og offentlige byggelogger ligger åpent på:
https://github.com/${FLOWFILE_REPO:-nordiccraft/FlowFile}
EOF
        hdiutil create \
            -volname "FlowFile ${NEW_VERSION}" \
            -srcfolder "$DMG_STAGE" \
            -fs APFS \
            -ov \
            -format UDZO \
            "$DMG_RELEASE" >/dev/null
        rm -rf "$DMG_STAGE_ROOT"

        echo "[release] Signing, notarizing & stapling DMG..."
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_RELEASE"
        xcrun notarytool submit "$DMG_RELEASE" "${NOTARY_AUTH_ARGS[@]}" --wait
        xcrun stapler staple "$DMG_RELEASE"
        xcrun stapler validate "$DMG_RELEASE"
        cp "$DMG_RELEASE" "$PROJECT_DIR/build/installers/"
    fi
else
    echo "[release] Building FlowFile v${NEW_VERSION} (ad-hoc / local mode)..."
    "$PROJECT_DIR/scripts/build-installer.sh"

    if [[ -f "$PROJECT_DIR/build/installers/FlowFile-${NEW_VERSION}-Installer.dmg" ]]; then
        cp "$PROJECT_DIR/build/installers/FlowFile-${NEW_VERSION}-Installer.dmg" "$DMG_RELEASE"
    fi

    echo "[release] Creating FlowFile-Update.zip..."
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/build/FlowFile.app" "$UPDATE_ZIP"
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

if [[ -n "${FLOWFILE_REPO:-}" && "${PUBLISH_GITHUB:-0}" == "1" ]]; then
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

    if [[ -f "$PROJECT_DIR/Casks/flowfile.rb" ]]; then
        ZIP_SHA256="$(shasum -a 256 "$UPDATE_ZIP" | awk '{print $1}')"
        python3 "$PROJECT_DIR/scripts/update-cask.py" "$PROJECT_DIR/Casks/flowfile.rb" "$NEW_VERSION" "$ZIP_SHA256"
        echo "[release] Updated Casks/flowfile.rb with version ${NEW_VERSION} and sha256 ${ZIP_SHA256} (commit & push to sync Homebrew)."
    fi
fi
