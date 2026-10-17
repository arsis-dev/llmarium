# Remplacer LiteLLM par le point d'entrée

## Fait le 17 octobre 2026

La bascule a pris une autre voie que celle décrite plus bas : LLMarium garde son port **18099**, et les clients ont été rebranchés dessus au lieu de passer le point d'entrée sur le port 4000.

- LiteLLM ne tournait déjà plus (port 4000 fermé). `~/Dev/server/llm-stack/start-all.sh` ne démarre plus que les runtimes et SearXNG ; le service `litellm` reste dans le `docker-compose.yml` pour revenir en arrière.
- Projets rebranchés sur `http://127.0.0.1:18099` : Watslog (fournisseurs `llmarium:local` et `llmarium:cloud`, migration du trousseau, du workflow et de la base), Spicilege, Namerkit (presets du trainer ; l'app n'injecte plus la clé de LiteLLM), Rhizomes (libellés seulement : sa configuration vise ds4 directement).
- Réglages rebranchés, avec une copie `.bak-llmarium-20261017-093212` à côté de chacun : `~/.config/opencode/opencode.json`, `~/.pi/agent/models.json` (fournisseur `local-gateway`), `~/.config/pulsed/config.yaml` (clé LiteLLM remplacée par `local`), `~/.zshrc` (`litellm-up/down/status` remplacés par l'alias `llmarium` et `llmarium-status`).
- Clés `deepseek` et `cline` : présentes dans le trousseau (étape 1 faite).
- Reste à faire : l'ouverture de LLMarium à la connexion (étape 8) et la vérification de configuration de Watslog (étape 7).

Les étapes ci-dessous restent valables pour la voie « port 4000 ».
