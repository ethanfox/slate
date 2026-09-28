#!/bin/sh
# Xcode build phase: compile the local agent runner and sign it into the app bundle.
set -eu

export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v bun >/dev/null || { echo "error: bun is required to build the agent runner (https://bun.sh)"; exit 1; }

cd "$SRCROOT/PersonalContextRunner"
bun install --frozen-lockfile

OUT="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/personal-context-runner"
WORK="$DERIVED_FILE_DIR/runner"
mkdir -p "$WORK"

SLICES=""
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64) TARGET=bun-darwin-arm64 ;;
    x86_64) TARGET=bun-darwin-x64 ;;
    *) echo "error: unsupported arch $ARCH"; exit 1 ;;
  esac
  bun build runner.ts --compile --target="$TARGET" --outfile "$WORK/runner-$ARCH"
  SLICES="$SLICES $WORK/runner-$ARCH"
done

lipo -create $SLICES -output "$OUT"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none \
  --entitlements runner.entitlements "$OUT"
