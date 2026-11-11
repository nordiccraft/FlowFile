#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="FlowFile"
APP_VERSION="${APP_VERSION:-1.0.0}"

BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
INSTALLER_OUT_DIR="$BUILD_DIR/installers"
DMG_FINAL="$INSTALLER_OUT_DIR/${APP_NAME}-${APP_VERSION}-Installer.dmg"

STAGE_ROOT="/tmp/flowfile-dmg-stage-$$"
DMG_STAGE="$STAGE_ROOT/dmg"

cleanup() {
    rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

"$PROJECT_DIR/scripts/build-app.sh" release

mkdir -p "$INSTALLER_OUT_DIR" "$DMG_STAGE"
rm -f "$DMG_FINAL"

if [[ "${SKIP_DMG:-0}" != "1" ]]; then
    echo "[installer] Creating drag-and-drop disk image (.dmg)..."
    ditto "$APP_BUNDLE" "$DMG_STAGE/${APP_NAME}.app"
    ln -s /Applications "$DMG_STAGE/Applications"

    cat > "$DMG_STAGE/README - Installasjon.txt" <<EOF
FlowFile ${APP_VERSION} for macOS
=================================

1. Dra «FlowFile.app» over på «Applications»-mappen.
2. Åpne FlowFile fra Programmer (Applications) eller Spotlight.

All kildekode og offentlige byggelogger ligger åpent på:
https://github.com/nordiccraft/FlowFile
EOF

    hdiutil create \
        -volname "${APP_NAME} ${APP_VERSION}" \
        -srcfolder "$DMG_STAGE" \
        -fs APFS \
        -ov \
        -format UDZO \
        "$DMG_FINAL" >/dev/null

    echo "[installer] DMG ready: $DMG_FINAL"
fi
