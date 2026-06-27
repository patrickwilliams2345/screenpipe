#!/bin/bash
set -e

# Clean up any existing bundle
rm -rf src-tauri/target/release/bundle

# Build without signing
bunx tauri build --no-sign

# Strip extended attributes from all files in the bundle
APP_PATH="src-tauri/target/release/bundle/macos/screenpipe - Development.app"
xattr -cr "$APP_PATH"

# Find a local Apple Development identity, or fallback to Louis's
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$IDENTITY" ]; then
  IDENTITY="Apple Development: Louis Beaumont (NJ372MT773)"
fi
echo "Using codesigning identity: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP_PATH"

echo "Build completed successfully!"
