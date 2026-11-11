#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
if [[ -f "$PROJECT_DIR/scripts/release-config.env" ]]; then
    source "$PROJECT_DIR/scripts/release-config.env"
fi
APP_NAME="FlowFile"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-100}"
BUNDLE_ID="com.flowfile.app"
FLOWFILE_REPO="${FLOWFILE_REPO:-nordiccraft/FlowFile}"

BUNDLE_DIR="$PROJECT_DIR/build/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS_FILE="$PROJECT_DIR/scripts/FlowFile.entitlements"

CONFIG="${1:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swiftpm-module-cache}"

echo "[build] Compiling $APP_NAME $APP_VERSION ($CONFIG)..."
swift build --disable-sandbox --package-path "$PROJECT_DIR" -c "$CONFIG" --cache-path /tmp/swiftpm-cache -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache

BIN_PATH="$(swift build --disable-sandbox --package-path "$PROJECT_DIR" -c "$CONFIG" --cache-path /tmp/swiftpm-cache --show-bin-path)/$APP_NAME"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$RESOURCES_DIR/nb.lproj" "$RESOURCES_DIR/en.lproj"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"

if [[ -f "$PROJECT_DIR/scripts/generate-icon.swift" ]]; then
    swift -module-cache-path /tmp/swift-module-cache "$PROJECT_DIR/scripts/generate-icon.swift" "$RESOURCES_DIR/AppIcon.icns" || true
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>nb</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>nb</string>
        <string>no</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>FFUpdateRepository</key>
    <string>${FLOWFILE_REPO}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>FlowFile trenger tilgang til Skrivebord-mappen for å vise, organisere og håndtere filene dine.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>FlowFile trenger tilgang til Dokumenter-mappen for å vise, organisere og håndtere filene dine.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>FlowFile trenger tilgang til Nedlastinger-mappen for å vise, organisere og håndtere filene dine.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>FlowFile trenger tilgang til eksterne disker og minnepinner for å bla gjennom og kopiere filer.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>FlowFile trenger tilgang til nettverksdisker og skylagringsvolumer for filhåndtering.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>FlowFile bruker lokalt Wi-Fi kun når du starter hurtigdeling av filer via QR-kode til mobil eller PC.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>FlowFile bruker Apple Events når du åpner mapper i Terminal eller sender vedlegg via e-postklienter.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

cat > "$RESOURCES_DIR/en.lproj/InfoPlist.strings" <<EOF
"NSDesktopFolderUsageDescription" = "FlowFile needs access to your Desktop folder to browse, organize, and manage your files.";
"NSDocumentsFolderUsageDescription" = "FlowFile needs access to your Documents folder to browse, organize, and manage your files.";
"NSDownloadsFolderUsageDescription" = "FlowFile needs access to your Downloads folder to browse, organize, and manage your files.";
"NSRemovableVolumesUsageDescription" = "FlowFile needs access to external drives and USB volumes to browse and transfer files.";
"NSNetworkVolumesUsageDescription" = "FlowFile needs access to network drives and cloud volumes for file management.";
"NSLocalNetworkUsageDescription" = "FlowFile uses your local Wi-Fi network only when sharing files via QR code to phones or PCs.";
"NSAppleEventsUsageDescription" = "FlowFile uses Apple Events when opening folders in Terminal or sending attachments to mail apps.";
EOF

cat > "$RESOURCES_DIR/nb.lproj/InfoPlist.strings" <<EOF
"NSDesktopFolderUsageDescription" = "FlowFile trenger tilgang til Skrivebord-mappen for å vise, organisere og håndtere filene dine.";
"NSDocumentsFolderUsageDescription" = "FlowFile trenger tilgang til Dokumenter-mappen for å vise, organisere og håndtere filene dine.";
"NSDownloadsFolderUsageDescription" = "FlowFile trenger tilgang til Nedlastinger-mappen for å vise, organisere og håndtere filene dine.";
"NSRemovableVolumesUsageDescription" = "FlowFile trenger tilgang til eksterne disker og minnepinner for å bla gjennom og kopiere filer.";
"NSNetworkVolumesUsageDescription" = "FlowFile trenger tilgang til nettverksdisker og skylagringsvolumer for filhåndtering.";
"NSLocalNetworkUsageDescription" = "FlowFile bruker lokalt Wi-Fi kun når du starter hurtigdeling av filer via QR-kode til mobil eller PC.";
"NSAppleEventsUsageDescription" = "FlowFile bruker Apple Events når du åpner mapper i Terminal eller sender vedlegg via e-postklienter.";
EOF

chmod -R u+rwX,go+rX "$BUNDLE_DIR"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --entitlements "$ENTITLEMENTS_FILE" --sign - "$BUNDLE_DIR"
else
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"
fi

codesign --verify --deep --strict "$BUNDLE_DIR"

echo "[build] Signed app bundle ready at: $BUNDLE_DIR"
