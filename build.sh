#!/bin/bash
# Compila UpdateBar.app — richiede solo i Command Line Tools (xcode-select --install)
#   ./build.sh          compila, installa in /Applications e avvia
#   ./build.sh --ci     compila solo e crea dist/UpdateBar.zip (usato dalle Release)
set -euo pipefail
cd "$(dirname "$0")"

CI_MODE=false
[[ "${1:-}" == "--ci" ]] && CI_MODE=true

# Build in una cartella temporanea: iCloud (Scrivania/Documenti) aggiunge attributi che rompono codesign
OUT="${TMPDIR:-/tmp}/UpdateBarBuild"
APP="$OUT/UpdateBar.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Apple Silicon + Intel
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0  UpdateBar.swift -o "$OUT/UpdateBar-arm64"
swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos13.0 UpdateBar.swift -o "$OUT/UpdateBar-x86_64"
lipo -create "$OUT/UpdateBar-arm64" "$OUT/UpdateBar-x86_64" -output "$APP/Contents/MacOS/UpdateBar"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"

if $CI_MODE; then
  mkdir -p dist
  rm -f dist/UpdateBar.zip
  ditto -c -k --keepParent "$APP" dist/UpdateBar.zip
  echo "✓ Creato dist/UpdateBar.zip"
  exit 0
fi

pkill -x UpdateBar || true
rm -rf /Applications/UpdateBar.app
ditto "$APP" /Applications/UpdateBar.app
open /Applications/UpdateBar.app
echo "✓ Installata e avviata: /Applications/UpdateBar.app"
