---
title: Local Model Launcher - Plan V2
type: feat
date: 2026-10-06
supersedes: docs/plans/2026-09-15-0903-feat-local-model-launcher-plan.md
execution: code
---

# Local Model Launcher - Plan V2

## Objectif

Un « Appothèque des modèles » : une app de barre de menus et une fenêtre unique pour voir les moteurs et modèles présents sur le Mac, lancer un modèle, l'ouvrir dans un harness d'un clic et remplacer LiteLLM par un point d'entrée local simple. Une CLI et un serveur MCP exposent les mêmes fonctions à Claude et aux scripts.

Ce plan remplace celui du 15 septembre 2026, conçu autour de llama-swap et d'une orchestration plus lourde que le besoin.

## Décisions de l'utilisateur (6 octobre 2026)

- **Moteurs V1 :** oMLX, MTPLX et mlx-serve.
- **Harness dès l'étape 3 :** Claude Code, Codex, Pi, OpenCode 2 et DeepSeek Harness.
- **Terminal :** Ghostty.
- **Point d'entrée :** un proxy intégré à l'app, sans LiteLLM ni llama-swap.
- **API distantes :** incluses dans le catalogue (DeepSeek, Cline…).
- **Hors V1 :** ds4 (lien `ds4flash.gguf` actuellement cassé), Ollama, LM Studio, jan, vllm-mlx, llama-swap, Hermes, Codex.app, Cline.app et Claude.app.

## Faits vérifiés sur la machine

Relevé du 6 octobre 2026 : M5 Max, 128 Go, macOS 27.0.1, disque plein à 99 % (36 Gio libres).

### Moteurs

| Moteur | Version / emplacement | Mode | Protocoles présents dans le code | Pilotage |
|---|---|---|---|---|
| oMLX | `oMLX.app`, serveur actif sur `127.0.0.1:8020` | Multi-modèles, géré par son app | chat, `/v1/messages`, `/v1/responses`, embeddings | **Rattacher** : `/v1/models/status`, `POST /v1/models/{id}/load` et `/unload`. Ne jamais lancer un second `omlx-server`. |
| MTPLX | 2.11.3 (Homebrew), `mtplx serve` | Un modèle par processus | chat, `/v1/messages`, `/v1/responses`, embeddings, rerank | **Lancer** le processus et le détenir. |
| mlx-serve | `/Applications/MLX-Serve.app/Contents/MacOS/mlx-serve` | Un modèle par processus | chat, `/v1/messages`, `/v1/responses` | **Lancer** le processus et le détenir. |

Appels d'outils prouvés à l'étape 0 : oMLX et MTPLX sur `/v1/messages` et `/v1/responses`. Restent à prouver : mlx-serve, et `/v1/chat/completions` avec outils. Détails dans [compatibility.md](../compatibility.md).

### Modèles

| Emplacement | Taille | Remarque |
|---|---|---|
| `~/.mlx-serve/models` | 186 Go | Dont Qwen3.8-Flash-Next mixed-4-8bit (100 Go) |
| `~/.omlx/models` | 99 Go | Dont Qwen3.8-Flash-Next oQ4e-mtp (99 Go) ; liens vers le cache HF pour d'autres modèles |
| `~/.cache/huggingface/hub` | 60 Go | Partagé par oMLX (liens) et divers projets ; les entrées Youssofal (MTPLX) n'y sont que des coquilles vides |
| `~/.mtplx/models` | ≈ 23 Go | Modèles MTPLX : Qwen3.5-4B (2,6 Go) et Qwen3.8-27B (20,7 Go) |

Le même modèle de base occupe environ 200 Go dans deux quantifications.

### Harness

| Harness | Version | Mécanisme | Écriture |
|---|---|---|---|
| Claude Code | 2.1.288 | Variables d'environnement : `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY=""`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `API_TIMEOUT_MS` | Aucune |
| Codex CLI | 0.154.0 | `CODEX_HOME` dédié et vide, options `-c model_provider=…`, `model_providers.<id>.base_url`, `env_key`, `wire_api="responses"`, `model_context_window`, `web_search="disabled"`, puis `-m` | Aucune (le `CODEX_HOME` dédié appartient à l'app) |
| Pi | 1.0.0 | Fournisseur dans `~/.pi/agent/models.json` (ou `PI_CODING_AGENT_DIR`), puis `--model <fournisseur>/<id>` | Une entrée gérée |
| OpenCode 2 | 2.0.8 (`opencode` et `opencode2` sont le même binaire) | Fournisseur dans `~/.config/opencode/opencode.json` ; service d'arrière-plan, option `--standalone` | Une entrée gérée |
| DeepSeek Harness | `DeepSeek Harness.app` | Couche de patch `~/.dsh/profiles/desktop/cordis.patch.yml`, entrée `llm-pi-ai`, protocole `openai-responses` par défaut ; secret dans `~/.dsh/.credentials.yaml` | Une entrée gérée |

Pièges connus pour Claude Code, repris de l'intégration oMLX : contexte d'au moins 48K, outil LSP à désactiver (il provoque un recalcul complet du prompt) et `useAutoModeDuringPlan: false`.

Les fichiers de Pi, OpenCode et DeepSeek Harness sont déjà modifiés par oMLX, MTPLX et Daymon (sauvegardes `.bak` présentes). L'app doit coexister avec eux.

### Terminal

Ghostty 1.3.1 expose en AppleScript `new window` avec une `new surface configuration` : `command`, `initial working directory` et `environment variables`. Cela demande l'autorisation Automation de macOS. Solution de repli : `open -na Ghostty.app --args -e <commande>`.

### Configurations et benchmarks existants

- oMLX interroge **omlx.ai** (`https://omlx.ai/api/benchmarks/best`) par puce, variante, mémoire, modèle et contexte. Il renvoie les meilleurs résultats de vitesse avec leurs réglages, applicables via `POST /api/models/{id}/settings/optimal`. oMLX accepte aussi une recette collée (`/settings/recipe`) et expose `/generation_config`.
- MTPLX fournit `mtplx tune` (profondeur MTP la plus rapide pour ce Mac) et des benchmarks intégrés.
- Les notes de `~/Dev/server/llm-stack/docs/07-history.md` et les commentaires de `litellm-config.yaml` contiennent des réglages mesurés (contexte, `--reasoning off`, timeouts).

### LiteLLM actuel

Docker sur OrbStack avec Postgres, port `4000`. Alias : `ds4-flash`, `qwen3.6-mtplx` (pointe vers `:8001` alors que le commentaire indique `:8010`), `qwen3.8-flash-next-mlx-serve`, `granite-embedding` (oMLX `:8020`), `deepseek-v4-pro`, `deepseek-v4-flash-api` et `cline/*`. Clients connus : Watslog, Pulsed et vMLX-chat.

## Décisions techniques

- **KTD1. Structure d'Appothèque.** Package Swift avec `LauncherCore`, l'app SwiftUI (macOS 26+) et un exécutable CLI qui sert aussi de serveur MCP stdio. L'app et la CLI appellent le même noyau. Aucune dépendance externe, sauf éventuellement pour le proxy (KTD7).
- **KTD2. Catalogue sous forme de données.** Un profil réunit un moteur, un modèle (identifiant upstream ou chemin), une quantification, un contexte, des flags et une recette. Chaque profil a un alias stable. La configuration machine vit dans `~/Library/Application Support/<App>/` ; le dépôt ne contient que des exemples.
- **KTD3. Deux sortes d'adaptateurs moteur.** « Rattacher » pour oMLX (piloter son API, jamais le démarrer ni l'arrêter). « Lancer » pour MTPLX et mlx-serve (processus détenus par l'app). Un registre conserve PID, instant de démarrage et exécutable. Aucun signal n'est envoyé à un processus que l'app n'a pas lancé.
- **KTD4. Mémoire avant tout chargement.** Estimation = poids sur disque + cache KV (d'après `config.json`) + marge, comparée à la mémoire disponible et aux processus présents. Par défaut, un seul gros modèle à la fois. Si le modèle ne tient pas, l'app propose quoi arrêter ou décharger ; elle ne le fait jamais seule. Chaque chargement mesure la mémoire réelle pour recaler l'estimation. Pour oMLX, utiliser son propre état (`/v1/models/status` : `final_ceiling`, tailles estimées et résidentes, secondes de chargement par Go) et tenir compte de son garde-fou, qui refuse des requêtes et évince des modèles sous pression (constaté à l'étape 0).
- **KTD5. Recettes de harness sous forme de données.** Pour chaque harness : variables, arguments, fichier géré, protocole requis et conditions (contexte minimal…). Un couple impossible est grisé avec sa raison, sans traduction de protocole.
- **KTD6. Écritures de configuration prudentes.** Une seule entrée gérée par fichier, sous l'identifiant `local-launcher`, sauvegardée et écrite de façon atomique. Le fichier est relu et validé avant remplacement. Les entrées d'oMLX, MTPLX, Daymon et de l'utilisateur ne sont jamais touchées. Un fichier illisible bloque l'écriture avec une explication. Les secrets restent dans le trousseau ou dans les stockages de secrets prévus par les harness, jamais dans les fichiers de config ni dans les arguments de commande.
- **KTD7. Proxy sans traduction.** Relais HTTP en streaming sur localhost. La seule transformation est la réécriture du champ `model` (alias → identifiant upstream). En V1, il route uniquement vers un moteur déjà actif ; sinon il renvoie une erreur claire qui nomme le profil à lancer. Le chargement à la demande viendra plus tard. Il reprend le port `4000` après l'arrêt de LiteLLM, pour que les clients restent inchangés. Il gère aussi les préfixes (`cline/*`) et `/v1/embeddings`. Dépendance à confirmer : SwiftNIO (ou Hummingbird), limitée à la cible du proxy, plutôt qu'un serveur HTTP écrit à la main sur Network.framework.
- **KTD8. « Validé » se prouve.** Pour chaque couple moteur × protocole, puis chaque harness : réponse en streaming, appel d'outil et réponse finale. La preuve enregistre les versions, le profil et la date.
- **KTD9. Ouverture dans Ghostty.** AppleScript avec commande, dossier et variables d'environnement, sans script temporaire. Repli sur `open -na`.

## Étapes

Chaque étape fournit une app utilisable. La CLI et le MCP grandissent avec elles.

### Étape 0 — Preuve manuelle (sans code) — faite le 6 octobre 2026

Résultats et enseignements dans [compatibility.md](../compatibility.md). Les quatre couples Claude Code / Codex × oMLX / MTPLX sont validés. Avec la config utilisateur, Codex envoie environ 97K tokens de prompt ; un `CODEX_HOME` dédié le ramène à environ 10K par tour.

Avec oMLX déjà actif, lancer Claude Code par variables d'environnement et Codex par options `-c` vers `127.0.0.1:8020`, puis demander à chacun un appel d'outil simple. Répéter une fois avec MTPLX.

**Terminé quand** `docs/compatibility.md` contient le résultat de chaque couple testé.

### Étape 1 — Inventaire (lecture seule)

- Détecter les moteurs : binaire, version, état et port, identité via `/v1/models`.
- Lister les modèles des quatre emplacements : taille, architecture, quantification et contexte maximal d'après `config.json`, moteurs compatibles.
- Vue disque : doublons d'un même modèle de base, liens cassés, modèles jamais lancés.
- Vue mémoire : mémoire disponible et pression, empreinte des processus (modèles chargés en premier).
- Interface : barre de menus et fenêtre comme Appothèque. CLI `status` et `models`. Outils MCP en lecture seule.

**Terminé quand** l'inventaire retrouve l'état du 6 octobre : oMLX actif sur 8020, Qwen3.8-Flash-Next en double, lien ds4 cassé, quatre emplacements et leurs tailles.

### Étape 2 — Moteurs et mémoire

- Démarrer et arrêter un profil : rattachement à oMLX (load/unload), lancement de MTPLX et mlx-serve.
- Disponibilité confirmée par l'identité du modèle, pas seulement par le port.
- Contrôle mémoire avant chargement, diagnostic de ce qu'il faut fermer, mesure réelle après chargement.
- Vérification KTD8 de chaque moteur sur chat, `/messages` et `/responses`.
- CLI et MCP : `start`, `stop`, `memory_check`.

**Terminé quand** le passage d'un profil MTPLX à un profil mlx-serve ne laisse aucun processus orphelin, et que l'écart entre mémoire estimée et mesurée est enregistré.

### Étape 3 — Harness

- Action « Ouvrir dans… » : modèle, harness, dossier → nouvelle fenêtre Ghostty.
- En V1, les harness pointent directement vers le port du moteur.
- Adaptateurs : Claude Code (variables), Codex (`-c`), Pi (fournisseur géré et `--model`), OpenCode 2 (fournisseur géré ; vérifier qu'il apparaît malgré le service d'arrière-plan) et DeepSeek Harness (patch `llm-pi-ai` géré, puis ouverture de l'app).
- Couples impossibles grisés avec leur raison.
- CLI et MCP : `open_in_harness`.

**Terminé quand** chacun des cinq harness termine une session avec appel d'outil sur un modèle local, et que la comparaison des fichiers montre les configurations utilisateur intactes hors entrée gérée.

### Étape 4 — Proxy, API distantes et sortie de LiteLLM

- Proxy KTD7. Fournisseurs distants avec leurs clés dans le trousseau et leurs protocoles déclarés.
- Action « Synchroniser » : tout le catalogue apparaît, via le proxy, dans les sélecteurs de Pi, OpenCode 2 et DeepSeek Harness.
- Migration des alias LiteLLM utilisés. Avant de basculer, vérifier quels clients appellent encore `ds4-flash`, puisque ds4 est hors V1.
- Arrêt de la stack Docker. Le `docker-compose.yml` reste en place pour un retour arrière.

**Terminé quand** Watslog fonctionne sans changement de configuration avec LiteLLM arrêté, et qu'une API distante est utilisable depuis un harness.

### Étape 5 — Recettes et benchmark

- Recettes de moteur et de modèle : flags, contexte, échantillonnage par défaut lu dans `generation_config.json`, pièges connus. Import des réglages déjà notés (`07-history.md`, commentaires LiteLLM).
- Pour oMLX : afficher et appliquer les meilleurs réglages d'omlx.ai pour ce M5 Max.
- Pour MTPLX : exploiter `mtplx tune`.
- « Demander à Claude » : via le MCP, Claude lit le contexte (machine, versions, modèle, mesures), cherche puis enregistre une recette (`get_context`, `save_recipe`).
- Benchmark : temps de chargement, délai avant le premier token, vitesse de lecture du prompt et de génération, pic mémoire, sur trois prompts fixes (court, long contexte, appel d'outil). Résultats rattachés à la recette.

**Terminé quand** trois profils de moteurs différents ont des benchmarks comparables dans une même vue.

### Étape 6 — Radar des modèles

- API Hugging Face filtrée : tâche texte ou image-texte, format MLX pour les moteurs V1, taille compatible avec la mémoire, auteurs suivis (mlx-community, unsloth, Youssofal, Jundot, ddalcu…), nouvelle quantification d'un modèle déjà présent.
- Liens Hugging Face mis en favori dans Spicilege.
- Actualisation quotidienne. Le téléchargement est une action explicite, précédée d'un contrôle de l'espace disque.

**Terminé quand** le radar présente une liste courte de modèles lançables sur ce Mac, sans modèles d'image ou de vidéo ni formats inutilisables.

## Risques

- Les appels d'outils peuvent échouer sur un couple moteur × protocole malgré la route. L'étape 0 puis KTD8 le détectent tôt.
- L'API de chargement d'oMLX et son comportement mémoire sont à confirmer en usage réel.
- L'automatisation de Ghostty dépend d'une autorisation macOS que l'utilisateur doit accorder.
- Le relais en streaming est la partie la plus risquée du code. Il arrive à l'étape 4, hors du chemin critique des harness.
- Les harness évoluent vite (Claude Code change de version presque chaque jour). Les recettes portent la version testée, et la version installée est vérifiée au lancement.
- Les fichiers de Pi, OpenCode et DeepSeek Harness sont aussi modifiés par oMLX, MTPLX et Daymon. Seule l'entrée `local-launcher` est gérée.
- Avec le disque plein, aucun téléchargement ni copie de poids n'est fait sans contrôle préalable.

## Questions ouvertes (non bloquantes)

- Nom de l'app et de la CLI.
- Dépendance SwiftNIO ou Hummingbird pour la cible du proxy (KTD7).
