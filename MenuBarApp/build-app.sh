#!/usr/bin/env bash
# Construye Batuta y lo instala en ~/Applications/Batuta.app
set -euo pipefail
cd "$(dirname "$0")"

echo "· compilando (release)…"
swift build -c release

APP_STAGING=".build/Batuta.app"
APP_DEST="$HOME/Applications/Batuta.app"

echo "· montando bundle…"
rm -rf "$APP_STAGING"
mkdir -p "$APP_STAGING/Contents/MacOS"
cp Info.plist "$APP_STAGING/Contents/Info.plist"
cp .build/release/Batuta "$APP_STAGING/Contents/MacOS/Batuta"

echo "· firmando (ad-hoc, sella el bundle completo)…"
codesign --force --deep -s - "$APP_STAGING"

echo "· empaquetando dist/Batuta.zip…"
rm -rf dist && mkdir -p dist
# --norsrc/--noextattr: sin AppleDouble (._*) en el zip — un unzip de CLI los
# dejaría dentro del bundle y podría invalidar el sello de la firma.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_STAGING" dist/Batuta.zip

echo "· instalando en ~/Applications…"
pkill -x Batuta || true
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$APP_STAGING" "$APP_DEST"

echo "· lanzando…"
open "$APP_DEST"
echo "listo: $APP_DEST  ·  para otro Mac: dist/Batuta.zip"
