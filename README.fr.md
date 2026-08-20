# VoxPrompt

App macOS de barre de menus pour la dictée vocale **100 % locale**. Maintiens une touche, parle, relâche : le texte est transcrit par Whisper sur le Neural Engine de ton Mac, puis collé dans l'app active. Alternative libre et gratuite à Superwhisper.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![License](https://img.shields.io/badge/license-MIT-blue)

[Version anglaise](README.md) · [Télécharger](https://github.com/charle-com/voxprompt/releases/latest)

## Fonctionnalités

- Transcription locale par Whisper, aucun envoi réseau hormis le téléchargement du modèle au premier lancement
- Transcription en continu : les phrases sont transcrites pendant que tu parles, le texte tombe environ une seconde après le relâchement
- Raccourci global maintenu (Option droite par défaut, configurable)
- HUD flottant avec waveform alimentée par le vrai signal du micro
- Choix explicite du microphone, pour qu'un casque Bluetooth qui se connecte ne vole pas l'entrée
- Glossaire de noms propres et de jargon, avec correction floue qui ne touche pas aux mots déjà valides
- Tableau de bord des autorisations dans les préférences (micro, accessibilité, automatisation) avec bouton de réparation
- Multilingue, les 99 langues de Whisper, détection automatique ou langue forcée
- Collage fiable dans l'app active, avec voie de secours pour les apps qui refusent les frappes simulées
- Rien d'ouvert au repos : aucun périphérique audio n'est mobilisé tant que tu n'as pas appuyé

## Installation

### En une commande (recommandé)

```bash
curl -fsSL https://raw.githubusercontent.com/charle-com/voxprompt/main/install.sh | bash
```

Le script télécharge la dernière version, vérifie sa signature face au certificat du projet, l'installe dans `/Applications` et la lance. Aucun `sudo`, rien d'autre n'est modifié. Cette voie évite aussi l'avertissement macOS décrit ci-dessous, un fichier récupéré par `curl` n'étant pas mis en quarantaine.

### Par le DMG

Récupère-le depuis la [dernière version publiée](https://github.com/charle-com/voxprompt/releases/latest), ouvre-le et glisse `VoxPrompt.app` dans `/Applications`.

macOS refusera le premier lancement : VoxPrompt est signée mais pas notarisée par Apple, la notarisation exigeant un compte développeur payant que ce projet n'a pas. Ouvre alors **Réglages Système > Confidentialité et sécurité**, descends jusqu'au message concernant VoxPrompt et clique sur **Ouvrir quand même**. C'est à faire une seule fois.

### Depuis les sources

```bash
git clone https://github.com/charle-com/voxprompt.git
cd voxprompt
./setup-signing.sh    # une seule fois, crée l'identité de signature persistante
./build.sh --install  # compile, vérifie la signature, installe dans /Applications
```

Xcode complet requis : WhisperKit et MLX ne compilent pas avec les seuls Command Line Tools.

## Fonctionnement

1. **Maintiens** ta touche. Un HUD apparaît en bas de l'écran avec la waveform en direct.
2. **Parle** normalement. L'audio est capturé en 16 kHz mono et découpé sur les pauses ; chaque morceau part en transcription pendant que tu continues.
3. **Relâche.** Il ne reste que la dernière phrase à transcrire. Le texte est collé là où se trouve ton curseur.

Au premier lancement, le modèle (632 Mo pour celui par défaut) est téléchargé une fois, avec la progression affichée dans le HUD. Ensuite tout vient du cache local.

## Autorisations

| Autorisation | Requise | Pourquoi |
|---|---|---|
| **Microphone** | Oui | Capturer ta voix. macOS le demande au premier lancement. |
| **Accessibilité** | Oui | Détecter la touche maintenue et coller le texte. À accorder dans les Réglages, macOS ne sait pas la demander par une fenêtre. |
| **Automatisation** | Optionnelle | Seulement comme voie de secours pour le collage dans les apps qui ignorent les frappes simulées. |

Les préférences affichent l'état des trois en direct et ouvrent le bon panneau des Réglages d'un clic.

## Dépannage

### La touche ne fait rien

L'accessibilité n'est pas accordée, ou a été révoquée en silence. Ouvre **Préférences > Accessibilité** dans VoxPrompt, l'état est affiché en direct. Si macOS montre VoxPrompt comme déjà autorisée alors que rien ne se passe, désactive puis réactive l'entrée, ou lance :

```bash
tccutil reset Accessibility fr.charlesneveu.voxprompt
```

puis relance VoxPrompt et accorde à nouveau.

### Le HUD affiche « Aucun son » alors que j'ai parlé

Vérifie le micro sélectionné dans **Préférences > Microphone**. Si tu compiles depuis les sources, assure-toi que la signature embarque bien le fichier d'entitlements : sous hardened runtime, macOS fournit silencieusement un flux rempli de zéros à une app dépourvue de `com.apple.security.device.audio-input`. `./build.sh` le vérifie et refuse de produire un bundle inutilisable.

### Le texte finit dans le presse-papier au lieu de l'app

Certaines apps refusent les frappes simulées. VoxPrompt bascule alors sur AppleScript, qui demande l'autorisation d'automatisation la première fois. Si l'app cible résiste quand même, passe **Préférences > Collage** sur `AppleScript uniquement`. Le texte reste toujours dans le presse-papier, un ⌘V manuel fonctionne.

### La transcription est lente ou se bloque

macOS 26.5.x embarque un bug CoreML qui fige l'inférence Whisper sur le Neural Engine et sur le GPU. VoxPrompt teste les moteurs disponibles au démarrage, retient le plus rapide qui fonctionne réellement pour ta version exacte de macOS, et retente automatiquement quand Apple publie un correctif. Un décodage bloqué est abandonné par un chien de garde au lieu de tourner indéfiniment. Pour forcer un nouveau test :

```bash
defaults delete fr.charlesneveu.voxprompt whisper.computeProfile
```

### Plus rien ne marche après avoir déplacé l'app

Une app lancée depuis un emplacement en quarantaine s'exécute depuis un volume temporaire en lecture seule, ce qui casse ses autorisations. Réinstalle avec le script en une ligne, ou lance `xattr -cr /Applications/VoxPrompt.app`.

## Modèles Whisper

| Modèle | Taille | Qualité |
|---|---|---|
| **Large v3 Turbo** (par défaut) | 632 Mo | Excellente, multilingue |
| Large v3 | 626 Mo | Maximale |
| Base | 74 Mo | Correcte |
| Tiny | 39 Mo | Test uniquement |

Changement de modèle depuis les préférences. Le nouveau modèle se télécharge au premier usage.

## Glossaire

Whisper est excellent sur la parole courante mais bute sur les noms propres (clients, marques, jargon). Ajoute-les dans **Préférences > Glossaire**, séparés par des virgules ou des retours à la ligne. Après chaque transcription, les mots proches sont corrigés avec la bonne orthographe et la bonne casse, tandis que les mots déjà valides sont laissés intacts.

```
Glossaire : Gandy, Kwanko, Shopify, Klaviyo

Whisper entend       ->  VoxPrompt écrit
« je vois Gandhi »   ->  « je vois Gandy »
« envoie sur Shopi » ->  « envoie sur Shopify »
```

## Signature et mises à jour

VoxPrompt est signée avec une identité auto-signée stable, ce qui permet à macOS de conserver l'autorisation d'accessibilité d'une version à l'autre. Elle n'est volontairement **pas** notarisée : la notarisation exige un compte Apple Developer payant.

La vérification de mise à jour est **désactivée par défaut**. Activée dans les préférences, elle interroge GitHub une fois par jour pour savoir si une version plus récente existe, puis ouvre simplement la page de la release. Aucun téléchargement automatique, aucun installateur en tâche de fond.

## Journal de débogage

Désactivé par défaut, le texte transcrit pouvant contenir des données sensibles.

```bash
launchctl setenv VOXPROMPT_DEBUG 1
```

Journal écrit dans `~/Library/Logs/VoxPrompt/voxprompt.log` en mode `0600`.

## Confidentialité

Ta voix ne quitte jamais ton Mac. Transcription intégralement locale, aucune API distante, aucune télémétrie, aucun SDK tiers. Le réseau n'est sollicité que deux fois, et toujours sous ton contrôle : le téléchargement du modèle au premier usage, et la vérification de mise à jour que tu dois activer toi-même. Détail dans [PRIVACY.md](PRIVACY.md).

## Licence

[MIT](LICENSE) · Charles Neveu
