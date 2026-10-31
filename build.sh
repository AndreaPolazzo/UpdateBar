#!/bin/bash
# Compila e installa UpdateBar.app — richiede solo i Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

# Build in una cartella temporanea: iCloud (Scrivania/Documenti) aggiunge attributi che rompono codesign
OUT="${TMPDIR:-/tmp}/UpdateBarBuild"
APP="$OUT/UpdateBar.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library UpdateBar.swift -o "$APP/Contents/MacOS/UpdateBar"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"

pkill -x UpdateBar || true
rm -rf /Applications/UpdateBar.app
ditto "$APP" /Applications/UpdateBar.app
open /Applications/UpdateBar.app
echo "✓ Installata e avviata: /Applications/UpdateBar.app"
