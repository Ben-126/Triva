# Triva

Triva est un moteur de recherche IA **privé et natif** pour iPhone, iPad et Mac. Pas de compte, pas de serveur : tout tourne sur ton appareil ou passe directement par les fournisseurs que **toi** tu choisis.

> ⚠️ **Projet en développement actif.** Triva n'est pas encore disponible sur l'App Store et l'expérience de recherche (le cœur de l'app) n'est pas encore fonctionnelle. Les écrans de configuration décrits ci-dessous, eux, sont utilisables dès aujourd'hui.

## Pourquoi Triva

La plupart des assistants de recherche IA passent par le serveur d'une entreprise, qui voit tes questions. Triva fait l'inverse :

- **Aucun compte, aucune authentification.** Tu ouvres l'app et tu l'utilises.
- **Aucun serveur intermédiaire.** Ni chez le développeur, ni ailleurs — la recherche et la génération de réponse se font directement entre ton appareil et les services que tu as choisis.
- **Tu choisis qui traite tes données**, écran par écran, moteur par moteur.

## Comment ça marche

### Moteur IA — 3 choix, au choix

1. **Apple Intelligence** — gratuit, tourne entièrement sur l'appareil (nécessite un iPhone/iPad/Mac compatible).
2. **Modèle MLX local** — un modèle IA téléchargé une fois puis exécuté hors-ligne sur l'appareil, en 2 tailles selon la puissance de ton matériel. Un mode d'essai permet de le tester avant de le télécharger en entier.
3. **Ta propre clé API** (BYOK — *Bring Your Own Key*) — connecte le fournisseur cloud de ton choix (OpenAI, Anthropic, ou tout service compatible) avec ta propre clé. Facturé directement par le fournisseur, jamais par Triva.

Ta clé API n'est **jamais envoyée nulle part par Triva** : elle est stockée uniquement dans le Trousseau (Keychain) de ton appareil.

### Recherche

Triva interroge des instances **SearXNG publiques** (un moteur de recherche open-source qui n'espionne pas), avec bascule automatique si une instance est indisponible. Tu peux aussi connecter ta propre clé Brave, Tavily ou Google Programmable Search pour des résultats plus fiables.

### Widgets

Uniquement des widgets qui ne demandent aucune clé API ni compte (météo, calculatrice) — pas de service tiers caché derrière une fonctionnalité en apparence gratuite.

## Où en est le projet

Triva se construit par étapes. Aujourd'hui, sont déjà en place :

- L'écran de choix du moteur IA (Apple Intelligence / MLX / BYOK cloud)
- Le téléchargement et la sélection des modèles MLX
- La configuration BYOK avec un catalogue multi-fournisseurs (OpenAI, Anthropic, et fournisseurs compatibles personnalisés)

Reste à venir avant une première expérience complète : le pipeline recherche → réponse, puis l'écran de conversation lui-même.

## Configuration requise

- iPhone, iPad ou Mac sous **iOS 27 / iPadOS 27 / macOS 27**
- Pour Apple Intelligence : un appareil compatible Apple Intelligence
- Aucune autre inscription ni configuration serveur

## Confidentialité

- Aucune télémétrie, aucun tracking
- Aucune donnée envoyée à un serveur intermédiaire
- Les clés API restent en local, dans le Trousseau de ton appareil
