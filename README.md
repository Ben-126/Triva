# Triva

App native **iOS / iPadOS / macOS** en **SwiftUI** (un seul projet Xcode), contrepartie native du projet web **Perplexica_ameliorer** (fork amélioré de Perplexica, renommé **Vane**).

## Règle fondamentale — zéro backend

- Aucun serveur, ni chez le développeur ni chez l'utilisateur.
- Toute la logique (classification, recherche, scraping, scoring, failover réseau) est réécrite **nativement en Swift**.
- Le code TypeScript de Vane sert uniquement de référence de lecture pour porter la logique — il n'est jamais exécuté par l'app.

## BYOK partout

Ni compte utilisateur, ni authentification. Chaque clé est optionnelle et stockée uniquement en **Keychain local**.

### 3 options IA
1. **Apple Intelligence** (Foundation Models) — gratuit, sur l'appareil
2. **MLX local**, en 2 tailles, téléchargement à la demande + mode essai — gratuit, sur l'appareil
3. **Clé API personnelle** (BYOK cloud) — payant selon le fournisseur

### Recherche
- Liste d'instances **SearXNG publiques**, avec bascule automatique (failover)
- Option BYOK recherche (Brave / Tavily / Google Programmable Search)

### Widgets
- Uniquement ceux sans clé API (météo Open-Meteo, calculatrice)

## Structure du projet

```
Triva/
├── Core/
│   ├── AI/            Sélection et intégration des fournisseurs IA (Apple Intelligence, MLX)
│   └── Networking/     Client SearXNG, failover entre instances
├── Features/
│   └── Onboarding/     Sélection du moteur IA et des modèles MLX
└── Resources/          Données embarquées (modèles MLX, instances SearXNG)

TrivaTests/              Tests unitaires (Swift Testing)
```

## Tests

Le projet utilise **Swift Testing**. Les tests unitaires accompagnent toute logique métier pure (scoring, classification, failover réseau).

```bash
xcodebuild test -scheme Triva -destination "platform=macOS"
```

## Configuration locale requise

Certains fichiers ne sont pas versionnés (voir `.gitignore`) car spécifiques à chaque machine ou utilisateur :

- **`Triva/Resources/searxng-instances.json`** — liste des instances SearXNG à utiliser. À créer localement (voir [searx.space](https://searx.space) pour des instances publiques à jour).
- **`.claude/`** — configuration locale de l'outillage de développement.

## Devices de test

- iPhone compatible Apple Intelligence
- Mac Apple Silicon

Le simulateur ne permet pas de tester Apple Intelligence ni les performances réelles de MLX.

## Priorité

Faire les choses proprement dès le départ plutôt que vite.
