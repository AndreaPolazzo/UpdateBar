#!/bin/bash
# Compila UpdateBar.app — richiede solo i Command Line Tools (xcode-select --install)
#   ./build.sh          compila, installa in /Applications e avvia
#   ./build.sh --ci     compila solo e crea dist/UpdateBar.dmg + dist/UpdateBar.zip (usato dalle Release)
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
  rm -f dist/UpdateBar.zip dist/UpdateBar.dmg
  ditto -c -k --keepParent "$APP" dist/UpdateBar.zip

  # DMG con finestra "trascina in Applicazioni"
  if command -v create-dmg >/dev/null; then
    create-dmg \
      --volname "UpdateBar" \
      --volicon AppIcon.icns \
      --window-pos 200 120 \
      --window-size 540 340 \
      --icon-size 112 \
      --icon "UpdateBar.app" 140 160 \
      --hide-extension "UpdateBar.app" \
      --app-drop-link 400 160 \
      dist/UpdateBar.dmg "$OUT/UpdateBar.app" || rm -f dist/UpdateBar.dmg
  fi
  if [[ ! -f dist/UpdateBar.dmg ]]; then
    # fallback semplice: app + collegamento ad Applicazioni
    STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/UpdateBar.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname UpdateBar -srcfolder "$STAGE" -ov -format UDZO dist/UpdateBar.dmg
  fi
  echo "✓ Creati dist/UpdateBar.dmg e dist/UpdateBar.zip"
  exit 0
fi

pkill -x UpdateBar || true
rm -rf /Applications/UpdateBar.app
ditto "$APP" /Applications/UpdateBar.app
open /Applications/UpdateBar.app
echo "✓ Installata e avviata: /Applications/UpdateBar.app"
