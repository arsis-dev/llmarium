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
