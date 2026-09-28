#!/bin/sh
# Xcode build phase: bundle the local agent runner for Node and embed a signed Node binary to run it.
set -eu

NVM_NODE="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1 || true)"
export PATH="$HOME/.bun/bin:${NVM_NODE:+$NVM_NODE:}/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v bun >/dev/null || { echo "error: bun is required to build the agent runner (https://bun.sh)"; exit 1; }
NODE="${NODE_BINARY:-$(command -v node || true)}"
[ -n "$NODE" ] || { echo "error: node is required to build the agent runner (https://nodejs.org)"; exit 1; }
NODE="$(readlink -f "$NODE")"
for ARCH in $ARCHS; do
  lipo -archs "$NODE" | tr ' ' '\n' | grep -qx "$ARCH" || { echo "error: $NODE has no $ARCH slice; set NODE_BINARY to a node that does"; exit 1; }
done

cd "$SRCROOT/PersonalContextRunner"
bun install --frozen-lockfile

MACOS="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
RUNNER="$RESOURCES/runner"
rm -f "$MACOS/slate-runner" "$MACOS/personal-context-runner" "$MACOS/personal-context-node" "$RESOURCES/runner.mjs"
rm -rf "$RUNNER"
mkdir -p "$RUNNER"

# The SDK loads its own chunk files at runtime, so it ships as installed packages instead of being bundled.
bun build runner.ts --target=node --format=esm --packages=external --outfile "$RUNNER/runner.mjs"
rsync -a --delete --exclude ".bin" --exclude "@types" --exclude "bun-types" --exclude "typescript" node_modules/ "$RUNNER/node_modules/"

cp "$NODE" "$MACOS/slate-node"
chmod 755 "$MACOS/slate-node"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none \
  --entitlements runner.entitlements "$MACOS/slate-node"
