#!/usr/bin/env bash
# Fabrique le DMG de distribution a partir de build/VoxPrompt.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="VoxPrompt"
APP="build/${APP_NAME}.app"
STAGE="build/dmg-stage"

fail() { echo ""; echo "❌ $1" >&2; exit 1; }

[[ -d "$APP" ]] || fail "$APP introuvable. Lance ./build.sh d'abord."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
DMG_OUT="build/${APP_NAME}-${VERSION}.dmg"
VOL_NAME="${APP_NAME} ${VERSION}"

# On ne distribue jamais un bundle dont la signature ne se verifie pas : l'utilisateur
# se retrouverait avec une app que macOS refuse d'ouvrir, ou pire, qui perd ses
# autorisations en silence.
echo "==> Verification de la signature avant packaging…"
codesign --verify --strict "$APP" || fail "Signature invalide, DMG non produit."
codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.device.audio-input" \
  || fail "Entitlement microphone absent, DMG non produit."

rm -rf "$STAGE" "$DMG_OUT"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Note d'installation visible des l'ouverture du DMG : l'app n'etant pas notarisee
# (pas de compte Apple Developer payant), macOS refuse le premier lancement tant que
# l'utilisateur n'a pas clique "Ouvrir quand meme" dans les Reglages.
cat > "$STAGE/LISEZ-MOI.txt" <<'EOF'
VoxPrompt, installation
=======================

1. Glissez VoxPrompt dans le dossier Applications (a cote).
2. Lancez VoxPrompt depuis le Launchpad ou le dossier Applications.
3. macOS affichera un avertissement : VoxPrompt est un logiciel libre signe mais
   non notarise par Apple (la notarisation exige un compte payant a 99 USD par an).
   Ouvrez alors Reglages Systeme > Confidentialite et securite, faites defiler
   jusqu'au message concernant VoxPrompt, puis cliquez sur "Ouvrir quand meme".
   Cette manipulation n'est demandee qu'une seule fois.

Alternative en une commande, sans cet avertissement :

   curl -fsSL https://raw.githubusercontent.com/charle-com/voxprompt/main/install.sh | bash

Autorisations demandees au premier lancement :
  - Microphone    : enregistrer votre voix.
  - Accessibilite : detecter la touche maintenue et coller le texte transcrit.

Tout fonctionne hors ligne. Aucune donnee ne quitte votre Mac.

Code source et documentation : https://github.com/charle-com/voxprompt
EOF

echo "==> Creation du DMG…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_OUT" > /dev/null

rm -rf "$STAGE"

# Un DMG telecharge recevra de toute facon l'attribut de quarantaine du navigateur ;
# on evite au moins d'en ajouter un des la fabrication.
xattr -cr "$DMG_OUT" 2>/dev/null || true

SIZE=$(du -h "$DMG_OUT" | cut -f1)
SHA=$(shasum -a 256 "$DMG_OUT" | cut -d' ' -f1)

echo ""
echo "✅ DMG pret : $DMG_OUT ($SIZE)"
echo "   SHA-256 : $SHA"
echo ""
echo "Publier :"
echo "  gh release create v${VERSION} \"$DMG_OUT\" --title \"v${VERSION}\" --notes-file CHANGELOG.md"
