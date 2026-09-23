# Hammerspoon — configuration de Pierre Lhoest

Raccourcis clavier macOS pilotés par [Hammerspoon](https://www.hammerspoon.org).

| Fichier | Touches | Rôle |
|---|---|---|
| `init.lua` | F13–F19, ⌃F | MEMCHROMEPAGES : mémoriser / rappeler des fenêtres Chrome par projet |
| `capture.lua` | F4, F5 | Capture de fenêtre ou de zone → coller dans un chat |
| `funkeys.lua` | F1, F2, F3 | Luminosité, vue éclatée |
| `assist.lua` | F11, F12 | Relecture d'un brouillon (Mail, WhatsApp) par Claude, puis collage |
| `secrets.lua` | — | Clé API Anthropic — **non versionné**, à créer : `return { anthropic = "sk-ant-…" }` |

Mode d'emploi complet : `Raccourcis-Hammerspoon-guide.md`.

## Installation

1. Installer Hammerspoon, l'autoriser dans Accessibilité et Enregistrement de l'écran.
2. Cloner ce dépôt dans `~/.hammerspoon`.
3. Créer `secrets.lua` (voir ci-dessus), `chmod 600`.
4. Réglages Système → Clavier : activer « Utiliser F1, F2… comme touches de fonction standard » ; libérer F11 (Mission Control → Afficher le bureau).
5. Hammerspoon → Reload Config. Le panneau de démarrage affiche la version.
