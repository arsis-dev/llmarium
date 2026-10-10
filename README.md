# Local Model Launcher

Voir les moteurs et modèles locaux du Mac, lancer un modèle en tenant compte de la mémoire, l'ouvrir d'un clic dans un harness et remplacer LiteLLM par un point d'entrée local simple. Dans l'esprit d'Appothèque : une app de barre de menus, une fenêtre unique, plus une CLI et un serveur MCP.

## État du projet

Projet expérimental créé le 15 septembre 2026, recadré le 6 octobre 2026. Étape 1 livrée : inventaire (app, CLI `lml` et serveur MCP). Étape 2 partiellement livrée (voir le plan pour ce qui reste) : modèles en mémoire avec leur lanceur, libération de la mémoire après confirmation, et lancement d'un modèle avec estimation de la mémoire. L'app ne supprime rien sur le disque.

## Utilisation

L'app **Modèles locaux** vit dans la barre de menus : modèles en mémoire, état des moteurs, mémoire et disque d'un coup d'œil. **Ouvrir la fenêtre** (⌘0) donne cinq sections :

- **En cours** : chaque processus qui garde un modèle en mémoire (serveur d'un moteur ou processus lancé hors moteur), avec sa mémoire, son port, depuis quand il tourne, **qui l'a lancé** et les clients connectés. Le lanceur est lu dans la chaîne des processus parents ; si le lanceur s'est terminé, il est reconstitué à partir de l'environnement hérité (app, session Claude Code et son titre, projet, outil), marqué « probable » et le processus est signalé orphelin. Seules quelques variables sans valeur sensible sont lues. Pour un serveur ComfyUI, l'app lit sa file de tâches : activité (génération en cours, en attente) et fichiers de modèles chargés par la génération (ou la dernière terminée). **Décharger le modèle…** (oMLX), **Libérer la mémoire de ComfyUI…** (après la génération en cours, sans l'interrompre) et **Arrêter le processus…** demandent une confirmation qui rappelle les clients connectés et le lanceur ; l'app vérifie que le PID désigne toujours le même processus. Si l'arrêt n'aboutit pas en 10 secondes, un arrêt forcé est proposé avec une seconde confirmation.

- **Moteurs** : oMLX, MTPLX et mlx-serve, avec version, port, réponse de l'API et modèles chargés. Pour oMLX, le plafond mémoire qu'il applique et l'état de chaque modèle qu'il connaît.
- **Radar** : les nouveaux modèles de langage au format MLX qui tiennent dans la mémoire de ce Mac et n'y sont pas encore, une fois par jour. Sources : tendances Hugging Face, nouveautés des auteurs suivis (par défaut mlx-community, lmstudio-community et les auteurs des modèles déjà présents), liens Hugging Face des favoris Spicilege (seules les adresses sont lues, en lecture seule). Chaque modèle dit pourquoi il est là (tendance, nouveau chez tel auteur, favori, même modèle de base qu'un modèle présent) et sur quels moteurs il tournera probablement ; les modèles écartés gardent leur raison. **Télécharger pour…** montre la taille, la destination et l'espace libre, refuse si le disque n'a pas 10 % de marge, puis lance le téléchargement dans Ghostty (`hf download` pour oMLX et MTPLX, `mlx-serve pull`).
- **Recettes** : pour chaque modèle de langage et chaque moteur qui peut le servir, les réglages appliqués au lancement (contexte, raisonnement pour MTPLX, température, top_p, top_k, options), avec leurs sources. Par défaut, seules les valeurs du `generation_config.json` du modèle et les pièges constatés dans ce projet ; rien n'est inventé. Pour oMLX, la recette est indicative (ses réglages vivent dans son app) et la section montre les meilleurs résultats publiés sur omlx.ai pour cette puce. **Demander à Claude…** ouvre Claude Code dans Ghostty avec le serveur MCP de l'app : il lit le contexte du modèle, cherche les réglages recommandés, les propose avec leurs sources et n'enregistre la recette qu'après accord. **Optimiser avec mtplx tune…** lance l'outil de MTPLX dans une fenêtre.
- **Bancs d'essai** : **Mesurer** sur une carte de **En cours** (ou `lml bench`) joue, directement sur le moteur et après un échauffement, une consigne courte, un texte d'environ 13K tokens avec un code caché à retrouver, et un appel d'outil. Il relève le délai avant le premier token, les vitesses de lecture et de génération, le pic mémoire, la présence de raisonnement, et signale une mesure perturbée par un autre client du moteur ou du GPU. Les résultats se comparent dans **Recettes**.
- **Point d'entrée** : une adresse locale unique, compatible OpenAI et Anthropic (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/v1/embeddings`, `/v1/models`), hébergée par l'app et activée dans la section du même nom. Elle relaie chaque requête vers le moteur qui sert le modèle demandé, ou vers une API distante (DeepSeek, Cline…) dont la clé est dans le trousseau ; seul le champ `model` est réécrit, les réponses en streaming passent telles quelles. Des **noms stables** (alias, importables depuis une configuration LiteLLM) visent un identifiant de modèle plutôt qu'un port ; un nom local ne part jamais vers une API distante. Elle n'écoute que sur 127.0.0.1 (port 18099 par défaut, 4000 pour remplacer LiteLLM : voir [la bascule](docs/bascule-litellm.md)). **Synchroniser** inscrit tous les modèles joignables dans Pi et DeepSeek Harness avec cette adresse, et **Ouvrir dans…** passe par elle quand elle est active.
- **Ouvrir dans un harness** : sur une carte de **En cours**, **Ouvrir dans…** propose Claude Code, Codex, Pi, OpenCode et DeepSeek Harness (grisés avec la raison s'ils ne sont pas installés ou si le contexte est trop court : Claude Code demande 48K). On choisit le dossier du projet ; une fenêtre Ghostty s'ouvre dans ce dossier avec le harness branché sur le modèle, puis reste ouverte sur un shell. Claude Code reçoit tout par variables d'environnement ; Codex utilise un dossier `CODEX_HOME` propre à l'app (prompt bien plus léger, sans vos skills ni MCP) ; OpenCode reçoit sa configuration par `OPENCODE_CONFIG_CONTENT` avec un serveur privé ; Pi reçoit une entrée `local-launcher` dans `~/.pi/agent/models.json` et DeepSeek Harness un fournisseur `local-launcher` dans sa couche de patch, chacun avec une sauvegarde datée et sans toucher au reste. La première ouverture demande d'autoriser l'app à piloter Ghostty.
- **Lancer un modèle** : dans **Modèles**, double-clic sur une ligne, **Lancer…** dans la barre d'outils ou le menu contextuel. La fenêtre propose les moteurs compatibles (et dit pourquoi les autres ne le sont pas), le contexte, puis estime la mémoire : poids (mesurés lors d'un chargement précédent, sinon taille sur disque), cache de contexte calculé d'après l'architecture, marge d'exécution, face à la mémoire disponible (pour oMLX, son propre plafond). Si le modèle ne tient pas, elle liste quoi libérer : modèles en cours, puis apps de plus de 2 Go. MTPLX et mlx-serve sont lancés sur 127.0.0.1, sur un port libre entre 18100 et 18199, avec un journal dans `~/Library/Application Support/LocalModelLauncher/Logs/` ; ils continuent de tourner si l'app est quittée. oMLX charge le modèle par son API et refuse lui-même ce qui ne tient pas.
- **Modèles** : les modèles des quatre emplacements (`~/.omlx/models`, `~/.mlx-serve/models`, `~/.mtplx/models`, cache Hugging Face), avec taille, format, architecture, quantification et contexte. Clic droit : **Afficher dans le Finder**, **Copier le chemin**.
- **Disque** : occupation réelle par emplacement (liens non suivis, chaque fichier compté une fois), modèles de même architecture, liens cassés et entrées vides du cache.
- **Mémoire** : mémoire utilisée, pression, plafond d'oMLX et plus gros consommateurs par app, moteur ou processus de modèle hors moteur.

### CLI

```sh
lml              # résumé : moteurs, modèles en mémoire, mémoire, disque
lml running      # modèles en mémoire et qui les a lancés
lml estimate Qwen3.8-27B --context 131072   # mémoire nécessaire et disponible
lml start Qwen3.5-4B-MTPLX                   # charge le modèle s'il tient (--force sinon)
lml open claude --model Qwen3.8 --dir ~/Dev/projet       # fenêtre Ghostty avec Claude Code sur ce modèle
lml open pi --model Qwen3.8 --headless "Résume README.md"  # une fois, sans interface
lml proxy                    # point d'entrée au premier plan (l'app l'héberge aussi)
lml proxy import-litellm ~/Dev/server/llm-stack/litellm-config.yaml
lml provider set-key deepseek   # saisie invisible, vers le trousseau
lml sync                     # Pi et DeepSeek Harness via le point d'entrée
lml recipe show Qwen3.5-4B-MTPLX                  # recette, sources et commande de lancement
lml recipe set Qwen3.5-4B-MTPLX --reasoning off   # recette modifiée
lml bench Qwen3.8-27B        # banc d'essai d'un modèle en mémoire ; lml bench list pour comparer
lml radar                    # nouveaux modèles lançables ici (--refresh, --all pour les écartés)
lml radar download mlx-community/Qwen3.8-27B-4bit --engine omlx   # après contrôle du disque
lml models       # modèles de langage (--all pour tout)
lml disk         # emplacements, même architecture, liens cassés, entrées vides
lml memory       # mémoire et plus gros consommateurs
lml status --json
```

### Serveur MCP

`lml mcp` expose en stdio `get_status`, `list_running_models`, `list_models`, `estimate_memory`, `get_disk_report`, `get_memory_report`, `get_model_context`, `list_recipes`, `list_benchmarks`, `get_radar` (lecture seule), `save_recipe`, `run_benchmark` `start_model`, qui refuse un modèle qui ne tient pas en mémoire, et `open_in_harness`, qui ouvre un harness pour l'utilisateur. L'arrêt et le déchargement restent réservés à l'app, après confirmation. Le binaire est livré dans l'app :

```sh
claude mcp add local-models -- "/chemin/vers/Modèles locaux.app/Contents/MacOS/lml" mcp
```

## Périmètre V1

- **Moteurs :** oMLX, MTPLX et mlx-serve.
- **Harness :** Claude Code, Codex, Pi, OpenCode 2 et DeepSeek Harness, ouverts dans Ghostty ou leur app.
- **Point d'entrée :** proxy local intégré sans traduction de protocole, avec API distantes, pour remplacer LiteLLM.
- **Ensuite :** recettes de configuration, benchmark et radar des nouveaux modèles.

## Documentation

- [Plan V2](docs/plans/2026-10-06-feat-model-launcher-plan.md)
- [Plan initial, remplacé](docs/plans/2026-09-15-0903-feat-local-model-launcher-plan.md)

## Développement

macOS 26+, Swift, sans dépendance externe. Même structure qu'Appothèque : le module `ModelCore`, l'app SwiftUI `LocalModelLauncher` et la CLI `lml`, qui sert aussi de serveur MCP.

```sh
swift test
bash build.sh    # produit dist/Modèles locaux.app, CLI incluse
```

L'interface est écrite directement en français pour cette première version, sans catalogue de traductions.

Données locales, dans `~/Library/Application Support/LocalModelLauncher/` : `launched.json` (serveurs lancés par l'app, nettoyé dès qu'ils s'arrêtent), `proxy.json` (port, noms stables, API distantes, sans clé), `recipes.json`, `benchmarks.json`, `radar.json`, `radar-settings.json`, `measurements.json` (mémoire réellement prise par chaque modèle chargé) et `Logs/`.

Les modèles, chemins propres à la machine, configurations générées et journaux restent hors du dépôt.
