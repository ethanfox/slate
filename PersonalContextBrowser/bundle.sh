#!/bin/sh
# Xcode build phase: ship Playwright MCP and Chromium with the app. The user never installs Node.
set -eu

NVM_NODE="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1 || true)"
export PATH="$HOME/.bun/bin:${NVM_NODE:+$NVM_NODE:}/opt/homebrew/bin:/usr/local/bin:$PATH"
NODE="${NODE_BINARY:-$(command -v node || true)}"
[ -n "$NODE" ] || { echo "error: node is required to bundle the browser runtime"; exit 1; }
NODE="$(readlink -f "$NODE")"
if [ -x "$(dirname "$NODE")/npm" ]; then
  NPM="$(dirname "$NODE")/npm"
else
  NPM="$(command -v npm || true)"
fi
[ -n "$NPM" ] || { echo "error: npm is required to bundle the browser runtime"; exit 1; }

RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
DEST="$RESOURCES/browser"
CACHE="$SRCROOT/PersonalContextBrowser/.cache"
mkdir -p "$CACHE" "$DEST"

cd "$SRCROOT/PersonalContextBrowser"
"$NPM" install --omit=dev --cache "$CACHE/npm"
rsync -a --delete --exclude ".bin" node_modules/ "$DEST/node_modules/"

export PLAYWRIGHT_BROWSERS_PATH="$CACHE/browsers"
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
"$NODE" "$SRCROOT/PersonalContextBrowser/node_modules/playwright-core/cli.js" install chromium
rsync -a --delete "$PLAYWRIGHT_BROWSERS_PATH/" "$DEST/browsers/"

# Launch Services starts this app outside Membrae's sandbox so Chromium can register Mach ports.
HELPER_BIN="$BUILT_PRODUCTS_DIR/membrae-browser"
HELPER_APP="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/Membrae Browser.app"
mkdir -p "$HELPER_APP/Contents/MacOS"
cp "$HELPER_BIN" "$HELPER_APP/Contents/MacOS/membrae-browser"
chmod 755 "$HELPER_APP/Contents/MacOS/membrae-browser"
cat > "$HELPER_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>membrae-browser</string>
	<key>CFBundleIdentifier</key>
	<string>com.ethanfox.PersonalContext.browser</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Membrae Browser</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
TEAM="${DEVELOPMENT_TEAM:-Z85NB2ZYMN}"
ENTITLEMENTS="$CACHE/helper.entitlements"
sed "s/Z85NB2ZYMN/${TEAM}/g" \
  "$SRCROOT/PersonalContextBrowser/PersonalContextBrowser.entitlements" > "$ENTITLEMENTS"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  "$HELPER_APP"
