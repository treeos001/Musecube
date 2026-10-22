#!/usr/bin/env bash
# Builds Musecube.app. Requires macOS 14+ with Xcode (or Command Line Tools).
#
#   ./build_app.sh            website edition -> build/Musecube.app
#   ./build_app.sh appstore   App Store edition (-D APPSTORE) -> build/appstore/Musecube.app
#   ./build_app.sh both       website edition in build/direct, and the App Store edition
#
# Direct edition: Developer ID build. Sparkle is embedded but does not check for updates until SU_FEED_URL and SU_PUBLIC_ED_KEY are real.
# App Store edition: Sparkle is not linked.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-default}"

build_one() { # $1 = direct|appstore, $2 = output .app path
  local EDITION="$1" APP="$2" FLAGS=() SCRATCH=".build-$1"
  export MUSECUBE_EDITION="$EDITION"   # read by Package.swift: appstore => no Sparkle
  [[ "$EDITION" == appstore ]] && FLAGS=(-Xswiftc -DAPPSTORE)
  # Universal binary (Apple silicon + Intel) when the toolchain supports it; native-only otherwise.
  local BIN_DIR
  if swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64 ${FLAGS[@]+"${FLAGS[@]}"}; then
    BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64 ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"
  else
    echo "Universal build unavailable; building for this Mac only." >&2
    swift build -c release --scratch-path "$SCRATCH" ${FLAGS[@]+"${FLAGS[@]}"}
    BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"
  fi
  rm -rf "$APP"
  # Sparkle keys (direct edition only). Placeholders => the app never starts the updater (no network requests).
  local SPARKLE_KEYS=""
  if [[ "$EDITION" == direct ]]; then
    SPARKLE_KEYS="  <key>SUFeedURL</key><string>${SU_FEED_URL:-https://example.invalid/REPLACE_ME/appcast.xml}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY:-REPLACE_WITH_EDDSA_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUEnableInstallerLauncherService</key><true/>
"
  fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Musecube" "$APP/Contents/MacOS/Musecube"
if [[ "$EDITION" == direct ]]; then
  [[ -d "$BIN_DIR/Sparkle.framework" ]] || { echo "Sparkle.framework missing in $BIN_DIR" >&2; exit 1; }
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
fi
cp Resources/tool_catalog.json "$APP/Contents/Resources/tool_catalog.json"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp Resources/AppIcon.icns Resources/AppIconLight.icns Resources/AppIconDark.icns "$APP/Contents/Resources/"
cp Resources/StatusBarIcon_18.png Resources/StatusBarIcon_36.png Resources/StatusBarIcon_54.png "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Musecube</string>
  <key>CFBundleDisplayName</key><string>Musecube</string>
  <key>CFBundleIdentifier</key><string>com.shukuinan.musecube</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Musecube</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>LSFileQuarantineEnabled</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$SPARKLE_KEYS  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><false/><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc sign with App Sandbox entitlements.
# Signing. Ad-hoc for now (no Apple Developer account yet).
local ENT=Musecube.entitlements
[[ "$EDITION" == appstore ]] && ENT=Musecube.appstore.entitlements
# Ad-hoc until SIGN_IDENTITY is set (Developer ID Application: … or Apple Distribution: …).
# Notarization still needs an Apple Developer account; see RELEASING.md.
local SIGN_ID="${SIGN_IDENTITY:--}"
local SIGN_OPTS=()
[[ "$SIGN_ID" != "-" ]] && SIGN_OPTS=(--options runtime --timestamp)
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --deep --sign "$SIGN_ID" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign "$SIGN_ID" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --entitlements "$ENT" "$APP"

echo "Built $EDITION: $(pwd)/$APP"
}

case "$MODE" in
  default)  build_one direct build/Musecube.app ;;
  direct)   build_one direct build/direct/Musecube.app ;;
  appstore) build_one appstore build/appstore/Musecube.app ;;
  both)     build_one direct build/direct/Musecube.app; build_one appstore build/appstore/Musecube.app ;;
  *) echo "usage: $0 [direct|appstore|both]" >&2; exit 2 ;;
esac
