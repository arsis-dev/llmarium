# LLMarium — rapport de nommage

10 octobre 2026. Historique complet des vagues : [naming-state.yaml](naming-state.yaml).

## Nom retenu

**LLMarium** — l'app macOS qui range, lance et branche les modèles de langage locaux.

- Prononciation : « elle-elle-ème-arium » en français, « el-el-em-AIR-ee-um » en anglais.
- Graphie : `LLMarium` pour l'app, `llmarium` pour le dépôt, le domaine et les paquets.

## Justification

- **Sens** : le suffixe *-arium* désigne un lieu qui conserve et montre (aquarium, herbarium, vivarium). Accolé à « LLM », il dit d'emblée ce que l'app contient : un lieu où vivent les modèles locaux, inventoriés et prêts à servir.
- **Famille** : même registre savant qu'Appothèque et Spicilège, sans reprendre le suffixe -thèque.
- **Langues** : « LLM » se dit de la même façon en français et en anglais, contrairement à « AI » / « IA ».
- **Son** : quatre syllabes régulières, sans ambiguïté d'orthographe une fois entendu.

## Disponibilité (vérifiée le 10 octobre 2026)

| Vérification | État | Source |
|---|---|---|
| llmarium.com | libre | RDAP |
| llmarium.dev | libre | RDAP |
| llmarium.io | incertain | RDAP sans réponse nette |
| llmarium.org | incertain | RDAP sans réponse nette |
| Compte ou organisation GitHub `llmarium` | libre | API GitHub (404) |
| Dépôts GitHub nommés llmarium | aucun | `gh search repos` |
| PyPI, npm, crates.io, conda-forge, Homebrew | libre | API des registres |
| Recherche web | aucun logiciel ni produit sous ce nom | recherche du 10 octobre 2026 |

« Libre » veut dire non enregistré au moment de la vérification, pas réservé. Recommandé : `llmarium.dev` (cohérent avec un outil de développeur) et, si le prix est raisonnable, `llmarium.com`.

## Marques

Aucune base de marques (INPI, EUIPO, USPTO) n'a été consultée : le projet est personnel et open source. Les noms proches trouvés en ligne (llmur, llmer, LLMR, Llamarine) sont des bibliothèques ou des modèles sans rapport, avec une orthographe distincte. « LLM » est un terme générique, pas une marque. À vérifier sur TMview et l'USPTO si l'app devient un produit distribué.

## Alternatives solides

1. **Almarium** — l'armoire à livres médiévale, avec le « lm » caché ; libre sur GitHub, en .dev et sur les registres.
2. **LLM Cellar** — la cave où l'on garde les modèles avant de les servir ; .com et .dev libres.
3. **LLM Loft** — court ; .com et .dev libres.

## Écartés pour collision

Paddock, Remuda, Relais, Mutatio, Loci, Lares, Alveo, Cella, LLM Hive, Haiven, Helm : outils LLM ou IA existants sous ce nom ou un nom très proche (détail dans `naming-state.yaml`).

## Prochaines étapes

1. Créer le dépôt GitHub `llmarium`.
2. Réserver l'organisation GitHub `llmarium` si l'on veut la garder (gratuit).
3. Réserver `llmarium.dev` (et éventuellement `llmarium.com`).
4. Renommer dans le projet : nom affiché de l'app (aujourd'hui « Modèles locaux »), identifiant de bundle, nom du paquet Swift et, si souhaité, de la commande `lml`.
