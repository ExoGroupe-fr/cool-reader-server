#!/bin/bash
# Builds the Mac app, build/Cool Reader Server.app, and a zip of it for a GitHub release:
#
#   Scripts/build-mac-app.sh
#
# Universal (Apple silicon and Intel) when this Swift can build for both, else for this Mac's processor only.
# Signed ad hoc, for the Mac that built it. To sign it for other Macs, set DEVELOPER_ID to a "Developer ID
# Application: …" identity in the keychain. To have Apple notarize it and staple the ticket, set NOTARY_PROFILE too,
# a profile saved with `xcrun notarytool store-credentials`, or an App Store Connect API key: NOTARY_KEY (the .p8
# file), NOTARY_KEY_ID and NOTARY_ISSUER.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Cool Reader Server"
PRODUCT=CoolReaderServerMac
APP="build/$NAME.app"
VERSION=$(sed -n 's/^ *static let version = "\(.*\)"$/\1/p' Sources/CoolReaderKit/Server/Routes/Context.swift)
[ -n "$VERSION" ] || { echo "No version in Sources/CoolReaderKit/Server/Routes/Context.swift." >&2; exit 1; }

ARCHS="--arch arm64 --arch x86_64"
if ! swift build -c release --product "$PRODUCT" $ARCHS; then
    echo "The universal build failed: building for $(uname -m) only." >&2
    ARCHS=""
    swift build -c release --product "$PRODUCT"
fi
BINARY="$(swift build -c release --product "$PRODUCT" $ARCHS --show-bin-path)/$PRODUCT"

rm -rf "$APP"
# The two .lproj folders tell macOS the app speaks English and French: its own panels follow.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/fr.lproj"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"

rm -rf build/AppIcon.iconset
swift Scripts/make-mac-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

# The folder descriptions are what macOS shows when it asks before the server reads a library in Documents, on
# the desktop, on an external or network drive; English here, French in fr.lproj.
READS="Cool Reader Server reads the books in the folders you add as libraries. It never changes them."
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$NAME</string>
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
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.pookee.CoolReaderServer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>fr</string>
    </array>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>$READS</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>$READS</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>$READS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Cool Reader Server talks to your devices and your router on the home network, so that Cool Reader finds it and reaches it.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>$READS</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>$READS</string>
</dict>
</plist>
EOF
plutil -lint -s "$APP/Contents/Info.plist"

LIT="Cool Reader Server lit les livres des dossiers ajoutés comme bibliothèques, sans jamais les modifier."
cat > "$APP/Contents/Resources/fr.lproj/InfoPlist.strings" <<EOF
"NSDesktopFolderUsageDescription" = "$LIT";
"NSDocumentsFolderUsageDescription" = "$LIT";
"NSDownloadsFolderUsageDescription" = "$LIT";
"NSLocalNetworkUsageDescription" = "Cool Reader Server échange avec vos appareils et votre box sur le réseau de la maison, pour que Cool Reader le trouve et le joigne.";
"NSNetworkVolumesUsageDescription" = "$LIT";
"NSRemovableVolumesUsageDescription" = "$LIT";
EOF
plutil -lint -s "$APP/Contents/Resources/fr.lproj/InfoPlist.strings"

xattr -cr "$APP"
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP"

ARCHITECTURES=$(lipo -archs "$APP/Contents/MacOS/$NAME")
case "$ARCHITECTURES" in
    *arm64*x86_64* | *x86_64*arm64*) FLAVOR=universal ;;
    *) FLAVOR=$ARCHITECTURES ;;
esac
ZIP="build/CoolReaderServer-$VERSION-mac-$FLAVOR.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}${NOTARY_KEY:-}" ]; then
    [ -n "${DEVELOPER_ID:-}" ] || { echo "Notarizing needs DEVELOPER_ID: Apple only notarizes apps signed with a Developer ID." >&2; exit 1; }
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY needs NOTARY_KEY_ID}" \
            --issuer "${NOTARY_ISSUER:?NOTARY_KEY needs NOTARY_ISSUER}" --wait
    fi
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "$APP ($VERSION, $ARCHITECTURES)"
echo "$ZIP"
