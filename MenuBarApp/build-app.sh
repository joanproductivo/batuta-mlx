#!/usr/bin/env bash
# Construye Batuta MLX y la instala en ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

BIN=BatutaMLX          # nombre del ejecutable y del target SPM
APP="Batuta MLX.app"   # nombre visible del bundle

if [[ ! -f "Resources/$BIN.icns" ]]; then
  echo "· generando el icono…"
  mkdir -p .build
  swift make-icon.swift
fi

echo "· compilando (release)…"
swift build -c release

APP_STAGING=".build/$APP"
APP_DEST="$HOME/Applications/$APP"

echo "· montando bundle…"
rm -rf "$APP_STAGING"
mkdir -p "$APP_STAGING/Contents/MacOS" "$APP_STAGING/Contents/Resources"
cp Info.plist "$APP_STAGING/Contents/Info.plist"
cp ".build/release/$BIN" "$APP_STAGING/Contents/MacOS/$BIN"
cp "Resources/$BIN.icns" "$APP_STAGING/Contents/Resources/$BIN.icns"

echo "· firmando (ad-hoc, sella el bundle completo)…"
codesign --force --deep -s - "$APP_STAGING"

echo "· empaquetando dist/$BIN.zip…"
rm -rf dist && mkdir -p dist
# --norsrc/--noextattr: sin AppleDouble (._*) en el zip — un unzip de CLI los
# dejaría dentro del bundle y podría invalidar el sello de la firma.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_STAGING" "dist/$BIN.zip"

echo "· instalando en ~/Applications…"
pkill -x "$BIN" || true
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$APP_STAGING" "$APP_DEST"

echo "· lanzando…"
open "$APP_DEST"
echo "listo: $APP_DEST  ·  para otro Mac: dist/$BIN.zip"
