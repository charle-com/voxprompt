#!/usr/bin/env bash
# Build VoxPrompt.app dans ./build/ — signé avec une identité persistante
# pour que macOS TCC (Accessibility) garde l'autorisation entre les rebuilds.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="VoxPrompt"
BUNDLE_ID="fr.charlesneveu.voxprompt"
BUILD_DIR="./build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
SIGNING_IDENTITY="VoxPrompt Developer"

# Xcode toolchain (WhisperKit/MLX a besoin du vrai Xcode, pas CommandLineTools)
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  SWIFT_BIN="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
else
  SWIFT_BIN="$(command -v swift)"
fi

echo "==> Swift build (release, arm64)…"
"${SWIFT_BIN}" build -c release --arch arm64

BIN_PATH="$("${SWIFT_BIN}" build -c release --arch arm64 --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Binaire introuvable: ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Bundle ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Icône — générée si absente
if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "==> Génération de l'icône…"
  "${SWIFT_BIN}" make-icon.swift Resources/AppIcon.icns
fi
cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${APP_DIR}/Contents/Info.plist"

# Signature — identité persistante si dispo, sinon ad-hoc en fallback
if security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
  echo "==> Signature avec '${SIGNING_IDENTITY}'…"
  codesign --force --deep --options runtime \
    --sign "${SIGNING_IDENTITY}" \
    --identifier "${BUNDLE_ID}" \
    "${APP_DIR}"
else
  echo "⚠️  Identité '${SIGNING_IDENTITY}' absente — signature ad-hoc."
  echo "    Lance ./setup-signing.sh pour arrêter de perdre l'autorisation Accessibility."
  codesign --force --deep --sign - "${APP_DIR}"
fi

echo ""
echo "✅ Build terminé : ${APP_DIR}"
echo ""
echo "Installer :"
echo "  open ${APP_DIR}"
echo ""
echo "Packager en DMG :"
echo "  ./package-dmg.sh"
