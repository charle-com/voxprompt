#!/usr/bin/env bash
# Crée un DMG installable à partir de build/VoxPrompt.app
set -euo pipefail

cd "$(dirname "$0")"

APP="build/VoxPrompt.app"
DMG_OUT="build/VoxPrompt.dmg"
VOL_NAME="VoxPrompt"
STAGE="build/dmg-stage"

if [[ ! -d "$APP" ]]; then
  echo "❌ $APP introuvable. Lance ./build.sh d'abord."
  exit 1
fi

rm -rf "$STAGE" "$DMG_OUT"
mkdir -p "$STAGE"

# Copie l'app + symlink /Applications pour drag-and-drop
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Création du DMG…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_OUT"

rm -rf "$STAGE"

SIZE=$(du -h "$DMG_OUT" | cut -f1)
echo ""
echo "✅ DMG prêt : $DMG_OUT ($SIZE)"
echo ""
echo "Pour installer :"
echo "  open $DMG_OUT"
echo "  puis glisser VoxPrompt.app dans /Applications"
