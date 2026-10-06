# Local Model Launcher

Voir les moteurs et modèles locaux du Mac, lancer un modèle en tenant compte de la mémoire, l'ouvrir d'un clic dans un harness et remplacer LiteLLM par un point d'entrée local simple. Dans l'esprit d'Appothèque : une app de barre de menus, une fenêtre unique, plus une CLI et un serveur MCP.

## État du projet

Projet expérimental créé le 15 septembre 2026, recadré le 6 octobre 2026. Le dépôt contient le plan ; aucune application n'est encore implémentée.

## Périmètre V1

- **Moteurs :** oMLX, MTPLX et mlx-serve.
- **Harness :** Claude Code, Codex, Pi, OpenCode 2 et DeepSeek Harness, ouverts dans Ghostty ou leur app.
- **Point d'entrée :** proxy local intégré sans traduction de protocole, avec API distantes, pour remplacer LiteLLM.
- **Ensuite :** recettes de configuration, benchmark et radar des nouveaux modèles.

## Documentation

- [Plan V2](docs/plans/2026-10-06-feat-model-launcher-plan.md)
- [Plan initial, remplacé](docs/plans/2026-09-15-0903-feat-local-model-launcher-plan.md)

## Développement

Stack Swift, sur le modèle d'Appothèque : un module partagé, une app SwiftUI et une CLI qui sert aussi de serveur MCP. Le manifeste et les commandes de développement seront ajoutés lors de l'implémentation.

Les modèles, chemins propres à la machine, configurations générées et journaux restent hors du dépôt.
