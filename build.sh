#!/usr/bin/env bash
# Construit VoxPrompt.app dans ./build/, signe avec une identite persistante et
# verifie la signature avant de rendre la main.
#
# Options :
#   ./build.sh              construit et verifie
#   ./build.sh --install    construit, verifie, puis installe dans /Applications
#                           (quitte proprement l'instance en cours d'abord)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="VoxPrompt"
BUNDLE_ID="fr.charlesneveu.voxprompt"
BUILD_DIR="./build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
SIGNING_IDENTITY="VoxPrompt Developer"
ENTITLEMENTS="./VoxPrompt.entitlements"
INSTALL_DIR="/Applications"

DO_INSTALL=0
[[ "${1:-}" == "--install" ]] && DO_INSTALL=1

fail() { echo ""; echo "❌ $1" >&2; exit 1; }

# ---------------------------------------------------------------- prerequis

# WhisperKit et MLX ont besoin du vrai Xcode, les Command Line Tools ne suffisent pas.
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  SWIFT_BIN="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
else
  fail "Xcode est introuvable dans /Applications. Les Command Line Tools ne suffisent pas pour compiler WhisperKit."
fi

# Signature : PAS de repli ad hoc silencieux. Une signature ad hoc change a chaque
# build, donc macOS revoque l'autorisation d'accessibilite a chaque fois ; mieux vaut
# echouer bruyamment que livrer une app qui perdra ses autorisations.
if ! security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
  fail "Identite de signature '${SIGNING_IDENTITY}' absente du trousseau.
   Lance ./setup-signing.sh une fois, puis relance ce script.
   Sans identite stable, macOS revoque l'accessibilite a chaque rebuild."
fi

[[ -f "${ENTITLEMENTS}" ]] || fail "Fichier d'entitlements introuvable : ${ENTITLEMENTS}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"

echo "==> VoxPrompt ${VERSION} (build ${BUILD_NUMBER})"

# ---------------------------------------------------------------- compilation

echo "==> Compilation Swift (release, arm64)…"
# --product : seul l'executable de l'app est necessaire ici. Le banc de mesure
# voxbench est un outil de developpement, inutile de le construire a chaque livraison.
"${SWIFT_BIN}" build -c release --arch arm64 --product "${APP_NAME}"

BIN_PATH="$("${SWIFT_BIN}" build -c release --arch arm64 --product "${APP_NAME}" --show-bin-path)/${APP_NAME}"
[[ -x "${BIN_PATH}" ]] || fail "Binaire introuvable : ${BIN_PATH}"

# ---------------------------------------------------------------- bundle

echo "==> Assemblage de ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "==> Generation de l'icone…"
  "${SWIFT_BIN}" make-icon.swift Resources/AppIcon.icns
fi
cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${APP_DIR}/Contents/Info.plist"

# ---------------------------------------------------------------- signature

# Pas de --deep : Apple le deconseille explicitement pour signer (il applique les memes
# options et entitlements a tout le code imbriqué et rate le code place hors des
# emplacements standards). Ce bundle est un binaire SwiftPM statique sans framework
# imbriqué, une signature simple du bundle suffit.
echo "==> Signature avec '${SIGNING_IDENTITY}' (hardened runtime + entitlements)…"
codesign --force \
  --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  --timestamp=none \
  "${APP_DIR}"

# ---------------------------------------------------------------- verification

echo "==> Verification de la signature…"

codesign --verify --strict --verbose=1 "${APP_DIR}" 2>&1 | sed 's/^/    /' \
  || fail "La signature ne se verifie pas."

# L'entitlement micro est vital : sans lui, macOS coupe le micro EN SILENCE sous
# hardened runtime (echantillons a zero, aucune erreur remontee). Verifie sur
# macOS 26.5.2. On refuse donc de livrer un bundle sans lui.
ENTS_OUT="$(codesign -d --entitlements - "${APP_DIR}" 2>&1)"
for key in "com.apple.security.device.audio-input" "com.apple.security.automation.apple-events"; do
  echo "${ENTS_OUT}" | grep -q "${key}" || fail "Entitlement manquant dans le bundle signe : ${key}"
  echo "    entitlement present : ${key}"
done

# Le designated requirement doit rester identique d'une version a l'autre, sinon macOS
# considere la nouvelle version comme une autre application et redemande toutes les
# autorisations. C'est exactement le symptome "chaque mise a jour casse les permissions".
DR="$(codesign -d -r- "${APP_DIR}" 2>&1 | grep '^designated' || true)"
EXPECTED_DR='designated => identifier "'"${BUNDLE_ID}"'" and certificate root = H"f02e0e43edfc229dc756a43190e3ed783cc6aeb9"'
echo "    ${DR}"
if [[ "${DR}" != "${EXPECTED_DR}" ]]; then
  echo ""
  echo "⚠️  Le designated requirement differe de celui des versions publiees."
  echo "    Attendu : ${EXPECTED_DR}"
  echo "    macOS redemandera toutes les autorisations aux utilisateurs existants."
fi

# La quarantaine declenche l'App Translocation : l'app s'execute alors depuis un volume
# temporaire en lecture seule, ce qui casse les autorisations et l'auto-mise a jour.
xattr -cr "${APP_DIR}" 2>/dev/null || true

echo ""
echo "✅ Build verifie : ${APP_DIR}"

# ---------------------------------------------------------------- installation

if [[ "${DO_INSTALL}" == "1" ]]; then
  echo ""
  echo "==> Installation dans ${INSTALL_DIR}…"
  # Remplacer le bundle d'une app en cours d'execution laisse le process actif avec un
  # binaire supprime : sa signature devient invalide et macOS lui retire ses acces.
  if pgrep -x "${APP_NAME}" > /dev/null; then
    echo "    arret de l'instance en cours…"
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || pkill -x "${APP_NAME}" || true
    for _ in $(seq 1 20); do pgrep -x "${APP_NAME}" > /dev/null || break; sleep 0.25; done
    pgrep -x "${APP_NAME}" > /dev/null && pkill -9 -x "${APP_NAME}" || true
    sleep 0.5
  fi
  rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
  cp -R "${APP_DIR}" "${INSTALL_DIR}/${APP_NAME}.app"
  xattr -cr "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true
  codesign --verify --strict "${INSTALL_DIR}/${APP_NAME}.app" || fail "Signature invalide apres installation."
  echo "✅ Installe : ${INSTALL_DIR}/${APP_NAME}.app"
  echo ""
  echo "Lancer :  open -a ${APP_NAME}"
else
  echo ""
  echo "Installer :  ./build.sh --install"
  echo "Packager  :  ./package-dmg.sh"
fi
