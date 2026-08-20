#!/usr/bin/env bash
#
# Installateur VoxPrompt.
#
#   curl -fsSL https://raw.githubusercontent.com/charle-com/voxprompt/main/install.sh | bash
#
# Telecharge la derniere version publiee, verifie sa signature, et l'installe dans
# /Applications. Aucun sudo, aucune donnee collectee, rien d'autre n'est modifie.
#
# Pourquoi passer par ce script plutot que par le DMG : un fichier telecharge par un
# navigateur recoit un attribut de quarantaine. Comme VoxPrompt n'est pas notarise par
# Apple (la notarisation exige un compte developpeur payant), cette quarantaine oblige
# a autoriser l'app a la main dans les Reglages Systeme. En passant par curl, le fichier
# n'est pas mis en quarantaine et l'installation se fait sans cette etape. La signature
# du bundle est verifiee ci-dessous avant toute copie.
set -euo pipefail

REPO="charle-com/voxprompt"
APP_NAME="VoxPrompt"
INSTALL_DIR="/Applications"
# Empreinte SHA-1 du certificat de signature de VoxPrompt. Une app qui ne correspond
# pas a cette empreinte n'a pas ete produite par l'auteur du projet.
EXPECTED_CERT="f02e0e43edfc229dc756a43190e3ed783cc6aeb9"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
info()  { echo "${BOLD}==>${RESET} $1"; }
ok()    { echo "${GREEN}✓${RESET} $1"; }
fail()  { echo "" >&2; echo "${RED}✗ $1${RESET}" >&2; exit 1; }

TMP="$(mktemp -d)"
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo ""
echo "${BOLD}Installation de VoxPrompt${RESET}"
echo "${DIM}Dictee vocale locale pour macOS${RESET}"
echo ""

# ------------------------------------------------------------------ prerequis

[[ "$(uname -s)" == "Darwin" ]] || fail "VoxPrompt fonctionne uniquement sur macOS."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MACOS_MAJOR" -ge 14 ]] || fail "macOS 14 (Sonoma) ou plus recent est requis. Version detectee : $(sw_vers -productVersion)."

[[ "$(uname -m)" == "arm64" ]] || fail "VoxPrompt necessite un Mac Apple Silicon (M1 ou plus recent).
   La transcription s'appuie sur le Neural Engine, absent des Mac Intel."

# ------------------------------------------------------------------ telechargement

info "Recherche de la derniere version…"
API_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")" \
  || fail "Impossible de contacter GitHub. Verifie ta connexion."

VERSION="$(echo "$API_JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
DMG_URL="$(echo "$API_JSON" | sed -n 's/.*"browser_download_url": *"\([^"]*\.dmg\)".*/\1/p' | head -1)"

[[ -n "$VERSION" ]] || fail "Aucune version publiee trouvee."
[[ -n "$DMG_URL"  ]] || fail "Aucun fichier DMG dans la derniere version (${VERSION})."

ok "Version ${VERSION}"

info "Telechargement…"
curl -fL# "$DMG_URL" -o "$TMP/VoxPrompt.dmg" || fail "Le telechargement a echoue."
ok "Archive telechargee ($(du -h "$TMP/VoxPrompt.dmg" | cut -f1))"

# ------------------------------------------------------------------ verification

info "Montage et verification de la signature…"
MOUNT="$(hdiutil attach "$TMP/VoxPrompt.dmg" -nobrowse -readonly -mountrandom /tmp \
  | grep -o '/tmp/[^ ]*$' | tail -1)"
[[ -n "$MOUNT" && -d "$MOUNT/${APP_NAME}.app" ]] || fail "Archive illisible ou incomplete."

codesign --verify --strict "$MOUNT/${APP_NAME}.app" 2>/dev/null \
  || fail "La signature de l'application est invalide. Installation interrompue."

DR="$(codesign -d -r- "$MOUNT/${APP_NAME}.app" 2>&1 | grep '^designated' || true)"
echo "$DR" | grep -qi "$EXPECTED_CERT" \
  || fail "L'application n'est pas signee par le certificat attendu. Installation interrompue.
   Obtenu : ${DR}"

ok "Signature conforme au certificat du projet"

# ------------------------------------------------------------------ installation

if pgrep -x "$APP_NAME" > /dev/null; then
  info "Fermeture de la version en cours d'execution…"
  osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || pkill -x "$APP_NAME" || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" > /dev/null || break; sleep 0.25; done
  pgrep -x "$APP_NAME" > /dev/null && pkill -9 -x "$APP_NAME" || true
  sleep 0.5
fi

info "Installation dans ${INSTALL_DIR}…"
if [[ ! -w "$INSTALL_DIR" ]]; then
  fail "Ecriture impossible dans ${INSTALL_DIR}. Relance avec les droits necessaires, ou installe le DMG a la main."
fi

rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -R "$MOUNT/${APP_NAME}.app" "${INSTALL_DIR}/${APP_NAME}.app"
# Pas de quarantaine sur un fichier recupere par curl, mais on s'en assure : un bundle
# en quarantaine est execute depuis un volume temporaire en lecture seule, ce qui casse
# ses autorisations et son installation.
xattr -cr "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true

codesign --verify --strict "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null \
  || fail "La signature est invalide apres copie. Supprime ${INSTALL_DIR}/${APP_NAME}.app et reessaie."

ok "VoxPrompt ${VERSION} installe"

# ------------------------------------------------------------------ lancement

info "Lancement…"
open -a "${INSTALL_DIR}/${APP_NAME}.app"

cat <<EOF

${GREEN}${BOLD}Installation terminee.${RESET}

VoxPrompt vit dans la barre de menus (icone en forme d'onde).

${BOLD}Deux autorisations a accorder au premier lancement :${RESET}
  ${BOLD}Microphone${RESET}      la fenetre s'affiche toute seule, acceptez.
  ${BOLD}Accessibilite${RESET}   Reglages Systeme > Confidentialite et securite >
                  Accessibilite, puis activez VoxPrompt.
                  Sans elle, la touche de dictee reste sans effet.

${BOLD}Utilisation :${RESET} maintenez la touche ${BOLD}Option droite${RESET}, parlez, relachez.
Le texte est transcrit sur votre Mac et colle la ou se trouve le curseur.

${DIM}Au premier usage, le modele de transcription (632 Mo) est telecharge une fois.${RESET}
${DIM}Ensuite, tout fonctionne hors ligne.${RESET}

Documentation : https://github.com/${REPO}
EOF
