# Compatibilité moteurs × harness

Une preuve « validée » demande une réponse en streaming, un appel d'outil puis une réponse finale correcte (plan V2, KTD8). Chaque ligne donne les versions et la date du test.

## Étape 0 — 6 octobre 2026

Méthode : un dossier de test isolé contient `secret.txt` avec un jeton aléatoire. Le harness doit lire ce fichier avec un outil, puis répondre exactement le jeton. Le modèle ne peut pas le deviner : un jeton correct prouve l'appel d'outil et la reprise après résultat.

Machine : M5 Max, 128 Go, macOS 27.0.1. Harness lancés sans interface (`claude -p`, `codex exec`), sans modifier les configurations de l'utilisateur.

| Harness | Moteur et modèle | Protocole | Résultat | Durée | Remarques |
|---|---|---|---|---|---|
| Claude Code 2.1.288 | oMLX, `Qwen3.8-Flash-Next-oQ4e-mtp` | `/v1/messages` | ✅ Read → jeton exact | 7,9 s | 2 tours. Avertissement `unrecognized_model` sans conséquence. |
| Claude Code 2.1.288 | MTPLX 2.11.3, `Qwen3.5-4B-MTPLX-Optimized-Speed` | `/v1/messages` | ✅ jeton récupéré | 7 s | 6 tours : le petit modèle tâtonne sur le chemin et recopie les numéros de ligne. Le protocole n'est pas en cause. |
| Codex CLI 0.154.0 | oMLX, `Qwen3.8-Flash-Next-oQ4e-mtp` | `/v1/responses` | ✅ `cat secret.txt` → jeton exact | 34 s | Inclut le rechargement du modèle (environ 73 Go). Nécessite un `CODEX_HOME` dédié, voir ci-dessous. |
| Codex CLI 0.154.0 | MTPLX 2.11.3, `Qwen3.5-4B-MTPLX-Optimized-Speed` | `/v1/responses` | ✅ jeton récupéré | 5 s | Mêmes réglages que ci-dessus. |
| Protocole seul (client Python) | oMLX, `Qwen3.8-Flash-Next-oQ4e-mtp` | `/v1/responses` en streaming | ✅ `function_call` puis texte final exact | 1,6 s + 2,6 s | Événements reçus : `function_call_arguments.delta`, `output_text.delta`, `reasoning_summary_text.delta`. |

Non testés à cette étape :
- **mlx-serve** : son modèle de 100 Go ne tient pas à côté de celui d'oMLX ;
- **Pi, OpenCode 2 et DeepSeek Harness** : prévus à l'étape 3 ;
- **`/v1/chat/completions` avec outils** : à couvrir à l'étape 2.

## Enseignements à reporter dans les recettes

### Codex

- **Utiliser un `CODEX_HOME` dédié et vide.** Avec la config habituelle (skills, plugins, MCP), le prompt pèse **97 133 tokens**. Avec `--ignore-user-config`, il en reste **70 694**, car les skills sont toujours chargés. Avec un `CODEX_HOME` vide, il descend à **environ 10 000 tokens par tour**. mlx-serve procède de la même façon.
- **Désactiver la recherche web avec `-c web_search="disabled"`.** Sinon MTPLX refuse la requête : l'outil hébergé `web_search` n'est pas disponible en local.
- **Fournisseur passé par options `-c`** : `model_providers.<id>.base_url`, `env_key`, `wire_api="responses"`, plus `model_context_window`. Aucun fichier modifié.
- **Avertissements sans conséquence** : « Model metadata … not found » (métadonnées de repli) et l'échec de lecture de `/models`, dont Codex attend un format propre à OpenAI.

### Claude Code

- Variables d'environnement seulement (voir le plan V2). `ANTHROPIC_API_KEY=""` neutralise une éventuelle clé réelle présente dans le shell.
- En mode `-p`, Bash s'est exécuté alors que seul `Read` était autorisé. Pour les tests automatisés, restreindre explicitement les outils disponibles.

### Mémoire

- oMLX a son propre garde-fou :
  - il **refuse une requête** dont le cache de contexte dépasse son plafond dynamique (prompt Codex de 97K tokens → 3,7 Go demandés, refusés) ;
  - il **évince un modèle** sous forte pression (12:22:38, avec le message `Evicting model … (pressure=hard)`) ;
  - il **refuse ensuite de le recharger** tant que le plafond reste trop bas (erreur 507).
- `/v1/models/status` d'oMLX donne `final_ceiling`, la taille estimée et résidente de chaque modèle, et `load_seconds_per_gb_estimate` (0,79 s/Go). Ce sont des données directement utiles au diagnostic mémoire.
- Pendant le test, d'autres processus occupaient la mémoire : le serveur `clef` de Watslog (17 Go, redémarré pendant l'essai) et un serveur GLiNER de Spicilege (3,8 Go). Le serveur MTPLX de test a atteint 11 Go avec un modèle de 2,6 Go. Ce sont exactement les processus que le diagnostic doit nommer.

## Effets du test sur la machine

- Le serveur MTPLX de test (port 18090) a été lancé puis arrêté proprement ; aucun processus ne reste.
- oMLX a évincé Qwen3.8-Flash-Next sous la pression, à laquelle ce serveur de test a contribué. Le modèle a été rechargé par le dernier test et est de nouveau chargé.
- Aucune configuration utilisateur n'a été modifiée. Les sessions Codex du test sont restées dans un `CODEX_HOME` temporaire.

## Lancement par l'app — 8 octobre 2026

| Moteur | Modèle | Résultat | Mesures |
|---|---|---|---|
| MTPLX 2.11.3 | `Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed`, contexte 64K | ✅ `lml start` : prêt en 8 s sur 127.0.0.1:18100, toujours actif après la fin de la CLI, attribué à « Modèles locaux » | Estimé : 5,5 Go (2,4 Go de poids, 2 Go de cache à 64K, 1,1 Go de marge). Mesuré : 3 Go au démarrage, 4 Go après deux requêtes. Second lancement refusé par le contrôle mémoire (7,2 Go nécessaires d'après la mesure, 6,5 Go disponibles). |
| oMLX 0.7.0 | `granite-embedding-311m` | ✅ chargé par l'API en 1 s, puis déchargé | — |
| oMLX 0.7.0 | `Qwen3.8-Flash-Next-oQ4e-mtp` (chargé par un client) | Mesure retenue : 73 Go réels | 104 Go estimés d'après le dossier : la mesure remplace désormais la taille sur disque |

- **Arrêt : le défaut venait de l'app, pas de MTPLX.** Le premier serveur lancé par l'app ignorait SIGTERM et SIGINT (`mtplx stop` a dû le tuer par SIGKILL), alors qu'un serveur lancé depuis un shell s'arrête en 2 s, même après une requête. Cause vérifiée : `posix_spawn` appelé depuis un fil Swift Concurrency transmettait l'état des signaux de ce fil. L'app réinitialise désormais les signaux au lancement (`POSIX_SPAWN_SETSIGDEF`, masque vide) ; un test le couvre. La reprise du test avec MTPLX attend que la mémoire le permette (114 Go sur 128 utilisés à ce moment). Aucun processus MTPLX orphelin n'est resté après l'arrêt forcé.
- **Le raisonnement de MTPLX est actif par défaut** : avec `max_tokens` bas, la réponse reste vide, car tout est consommé par le raisonnement. À intégrer aux recettes (`--reasoning off` pour les clients qui attendent du texte ou du JSON).
- mlx-serve écoute par défaut sur `0.0.0.0` : l'app impose `--host 127.0.0.1`. Son lancement réel reste à prouver.

## Harness ouverts par l'app — 9 octobre 2026

Modèle : `Qwen3.8-27B-Huihui-Abliterated-oQ6e-MTP-MLX` sur oMLX 0.7.0 (déjà chargé), même méthode du jeton qu'à l'étape 0, via `lml open <harness> --headless`.

| Harness | Mécanisme | Protocole | Résultat | Durée |
|---|---|---|---|---|
| Claude Code 2.1.288 | Variables d'environnement, config utilisateur complète (plugins, hooks, MCP) | `/v1/messages` | ✅ | 44 s |
| Codex CLI 0.154.0 | `CODEX_HOME` propre à l'app | `/v1/responses` | ✅ ≈ 10 000 tokens | 24 s |
| Pi 1.0.0 | Entrée `local-launcher` dans `models.json` | `/v1/chat/completions` | ✅ | 13 s |
| OpenCode 2.0.8 | `OPENCODE_CONFIG_CONTENT` + `--standalone` | `/v1/chat/completions` | ✅ outil Read | 45 s (36 s au premier essai manuel) |
| DeepSeek Harness | Fournisseur `local-launcher` dans `cordis.patch.yml` | `openai-completions` | ⏳ patch validé sur copie ; session dans l'app à faire | — |

- Fenêtre Ghostty : Claude Code ouvert pour de bon dans le dossier choisi, sur le bon modèle.
- Ghostty avait été démarré depuis une session Claude Code et passait ses variables `CLAUDE_*` à toutes ses fenêtres (`CLAUDE_CODE_CHILD_SESSION` coupait l'historique de Claude Code). Les fenêtres ouvertes par l'app effacent ces marqueurs, sauf les variables qu'elle définit.
- Le fournisseur DeepSeek Harness déclare `apiKeyEnv: LOCAL_LAUNCHER_API_KEY`, comme votre fournisseur `dwarfstar` ; l'app ouverte par `open` ne reçoit pas cette variable. À vérifier lors de la première session.

## Point d'entrée — 9 octobre 2026

Port de test 18099, modèle `Qwen3.8-27B-Huihui-Abliterated-oQ6e-MTP-MLX` sur oMLX.

| Essai | Résultat |
|---|---|
| `GET /v1/models` avec `Authorization: Bearer litellm:local` via `localhost`, comme Watslog | ✅ 200 (client replié sur 127.0.0.1) |
| Chat en streaming | ✅ 26 morceaux, premier à 1,55 s, puis toutes les ~0,22 s jusqu'à 8,7 s : rien n'est retenu |
| Claude Code `-p` avec `ANTHROPIC_BASE_URL` sur le proxy, appel d'outil | ✅ 33 s, deux requêtes `/v1/messages` |
| Alias `qwen3.8-27b-abliterated` (chat) et `granite-embedding` (`/v1/embeddings`) | ✅ réécrits vers l'identifiant d'oMLX |
| Corps de 5 Ko avec `Expect: 100-continue` (curl) | ✅ réponse en 1 ms, sans l'attente d'une seconde |
| `deepseek-v4-pro` sans clé | ✅ 503 qui nomme la commande pour ajouter la clé |
| `ds4-flash` (ds4 arrêté) | ✅ 404 « local seulement », jamais envoyé à l'API DeepSeek |
| Faux moteur en test, trois événements à 300 ms | ✅ reçus étalés, `model` réécrit, `Connection: close` |

Non testé : une API distante réelle (aucune clé saisie), Watslog branché sur le proxy (bascule non faite).

## Bancs d'essai — 9 octobre 2026

| Modèle | Moteur | Génération | Lecture | 1er token | Outil | Contexte long | Pic mémoire | Conditions |
|---|---|---|---|---|---|---|---|---|
| Qwen3.8-27B-Huihui-Abliterated-oQ6e-MTP-MLX | oMLX 0.7.0 | 3,7 tok/s | 126 tok/s | 12,8 s | ✓ | ✓ | 70,9 Go (tout oMLX) | ⚠︎ Pi utilisait le même modèle |
| Qwen3.5-4B-MTPLX-Optimized-Speed (`--reasoning off`) | MTPLX 2.11.3 | 33,1 tok/s | 1 690 tok/s | 0,23 s | ✓ | ✓ | 7,1 Go | ⚠︎ oMLX traitait une requête (GPU partagé) ; chargé en 10 s |

- Référence omlx.ai pour le 27B sur M5 Max (64 Go, contexte 4K) : 23,4 tok/s en génération, 870 en lecture. L'écart avec la mesure d'oMLX vient du partage avec Pi : à refaire au calme.
- La recette MTPLX `--reasoning off` est bien passée au serveur (`--reasoning-mode off`) et le banc n'a reçu aucun raisonnement.
- Le serveur MTPLX lancé par l'app s'est arrêté en 2 s sur SIGTERM : la correction des signaux de l'étape 2 est confirmée en réel.
- mlx-serve non mesuré : 107 Go nécessaires, 43,8 Go disponibles.

## Radar — 9 octobre 2026

`lml radar --refresh` en 3,3 s : tendances MLX, nouveautés de 6 auteurs (30 jours), 19 modèles parmi les 33 liens Hugging Face de Spicilege. 19 modèles retenus, 91 écartés : 44 hors des 40 premiers candidats examinés, 17 pas au format MLX, 8 d'extraction de caractéristiques, 4 déjà sur ce Mac, 3 audio, 3 synthèse vocale… Aucun modèle d'image, de vidéo ou d'audio retenu ; le plus gros fait 95,2 Go pour 120 Go utilisables.

Extrait :

| Modèle | Taille | Moteur probable | Raisons |
|---|---|---|---|
| orcarouter/Qwen3.8-27B-Uncensored-MLX | 94,6 Go | oMLX ou mlx-serve | Tendance · même base que le 27B MTPLX présent · ⚠︎ plusieurs variantes dans le dépôt |
| Jundot/clef-oQ4e | 17 Go | oMLX | Tendance · nouveau chez Jundot (2 jours) · même base (Cloudflare/clef) que mlx-community/clef-4bit |
| Youssofal/Ternary-Bonsai-2-27B-MTPLX-Optimized-Speed | 8,8 Go | MTPLX | Tendance · nouveau chez Youssofal · même base (Qwen/Qwen3.8-27B) que le 27B MTPLX présent |
| ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw | 75,3 Go | mlx-serve | Tendance · nouveau chez ddalcu (7 jours) |
| JANGQ-AI/MiniMax-M2.7-JANG_3L | 95,2 Go | oMLX ou mlx-serve | Favori Spicilege du 12 avr. 2026 |

Au premier passage, la tête de liste (`mohit67890/imajev-4b`, 981 Mo) était un adaptateur LoRA de Qwen3.5-4B, inutilisable seul : les adaptateurs sont désormais écartés, et les dépôts à plusieurs variantes signalés (leur taille est la somme, et `hf download` les prend toutes). Moteurs attribués d'après l'auteur et le nom (« probable »). Non vérifié : un téléchargement réel, et le moment où oMLX découvre un modèle arrivé dans le cache Hugging Face.

## Étape 7 — 10 octobre 2026

M5 Max (GPU 40 cœurs, `gpu-core-count` lu dans l'I/O Registry), 128 Go.

- **Plafond du GPU** : `recommendedMaxWorkingSetSize` vaut 120 Go, et `iogpu.wired_limit_mb` est relevé à 122 880 : Metal reflète bien ce réglage. Le plafond d'oMLX (58 Go) est un réglage distinct. Pour le 27B MTPLX à 64K : 25,2 Go nécessaires, 22,4 Go de mémoire libre, 111 Go de GPU disponible ; c'est la mémoire libre qui bloque.
- **Vitesse** : bande passante de 614 Go/s (M5 Max 40 cœurs ; 460 Go/s pour 32 cœurs, d'après les fiches Apple relayées par la presse en mars 2026). Bornes calculées : Qwen3.8-27B MTPLX (19,3 Go, dense) ≤ 30 tok/s ; Qwen3.8-Flash-Next oMLX (MoE, 10 experts sur 512 par token, 2,7 Go lus par token) ≤ 214 tok/s. Le 4B MTPLX affiche sa mesure du 9 octobre (33 tok/s, perturbée). Les deux mesures existantes sont perturbées : aucune ne sert d'étalonnage.
- **Arrêt pour inactivité** : un serveur mlx-serve au repos consomme 0,000 s de CPU par 10 s (sondages de l'app compris) ; MTPLX au repos environ 0,12 s par minute, et une requête de 5 tokens 0,13 s. Le CPU seul ne distingue donc pas une petite requête du repos sur MTPLX : MTPLX écrit une ligne par génération dans son journal, et la croissance du journal compte comme activité (seuil CPU fixé à 0,5 s par minute). `proc_pid_rusage` compte en ticks Mach (125/3 ns sur cette puce).
- Essai réel avec `llmarium start Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed --idle 1` : sans requête, arrêt par l'app une minute après le premier relevé (11:23) ; avec une requête de 5 tokens à 11:25:20, activité notée par le journal à 11:25:45, arrêt vers 11:26:50 ; `launched.json` vidé à chaque fois.
- **Radar** : `llmarium radar --usage code` ne garde que `mlx-community/gemma-4-12b-coder-…` (Code, Raisonnement, Chat · ≤ 92 tok/s). Usages lus dans le nom (mots entiers) et les étiquettes Hugging Face.
- **Corbeille** : vérifiée seulement par les tests sur dossiers temporaires (dépôt Hugging Face entier, lien seul, liens dépendants, refus d'un modèle en mémoire). Aucun modèle réel n'a été mis à la corbeille.
