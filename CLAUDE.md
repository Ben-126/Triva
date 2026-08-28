# Triva — CLAUDE.md

## Contexte du projet

**Triva** (nom validé par Ben le 2026-08-27 — voir section *Nom de l'app*) est une app native multiplateforme **iOS/iPadOS/macOS**, en **SwiftUI**, un seul projet Xcode.

C'est la contrepartie native du projet web **Perplexica_ameliorer** (chemin : `~/Claude_code/Perplexica_ameliorer`), lui-même un fork amélioré de Perplexica renommé **"Vane"**.

La feuille de route détaillée est dans **`plan_a_suivre_ios.md`**, situé dans `Perplexica_ameliorer`. **Toujours s'y référer avant de commencer une tâche.**

---

## Règle fondamentale — zéro backend

- **Aucun serveur**, ni chez moi ni chez l'utilisateur.
- Toute la logique (classification, recherche, scraping, scoring, widgets) est **réécrite nativement en Swift** dans l'app.
- Le code TypeScript de `Perplexica_ameliorer` sert **uniquement de référence de lecture** pour comprendre la logique à porter — **ne jamais le modifier**.

---

## BYOK partout

- **Ni compte utilisateur, ni authentification.**
- Chaque clé (IA cloud, recherche) est **optionnelle**, stockée uniquement en **Keychain local**, jamais transmise à un serveur intermédiaire puisqu'il n'y en a pas.

### 3 options IA
1. **Apple Intelligence** (Foundation Models) — gratuit, sur l'appareil
2. **MLX local** en 2 tailles, avec téléchargement à la demande et mode essai — gratuit, sur l'appareil
3. **Clé API personnelle** (BYOK cloud) — payant selon fournisseur

### Recherche
- Liste d'instances **SearXNG publiques** par défaut (bascule automatique), zéro hébergement de ma part.
- Option **BYOK recherche** (Brave / Tavily / Google Programmable Search) pour plus de fiabilité.

### Widgets
- Uniquement ceux **sans clé API** (météo Open-Meteo, calculatrice).
- Widget bourse **exclu**, sauf alternative gratuite trouvée.

---

## Tests

- **Swift Testing** activé.
- Écrire des **tests unitaires en même temps que le code** pour toute logique métier pure (scoring, classification, failover réseau) — pas seulement du test manuel.

---

## App Store

- Contraintes prises en compte **dès le début**, même si la publication n'est pas encore décidée :
  - App Privacy Label
  - Taille des téléchargements MLX
  - Guidelines Apple

---

## Devices de test disponibles

- iPhone compatible Apple Intelligence
- Mac Apple Silicon

**Pas d'iPhone ancien ni d'iPad réel** — le simulateur ne peut pas tester Apple Intelligence ni les vraies performances MLX sur matériel faible.

---

## Nom de l'app

"Triva" est le **nom validé** (confirmé par Ben le 2026-08-27, tâche 0.1.4 du plan). Le Bundle ID / icône peuvent être figés définitivement sur cette base.

---

## Priorité

**Faire les choses proprement dès le départ plutôt que vite.**

---

## Suivi automatique du plan

Quand on me demande de traiter une tâche numérotée du plan (ex : "fais le 0.5"), je dois **automatiquement**, sans qu'on ait besoin de le redemander à chaque fois :

1. Lire `~/Claude_code/Perplexica_ameliorer/plan_a_suivre_ios.md`
2. Trouver la section correspondant au numéro donné
3. Suivre sa checklist telle qu'elle est écrite dans le plan

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
