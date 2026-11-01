# Triva

Triva est un moteur de recherche IA **privé et natif** pour iPhone, iPad et Mac. Pas de compte, pas de serveur : tout tourne sur ton appareil ou passe directement par les fournisseurs que **toi** tu choisis.

> ⚠️ **Projet en développement actif.** Triva n'est pas encore disponible sur l'App Store. Le cœur de l'app — poser une question, obtenir une réponse sourcée — fonctionne déjà ; les fonctions avancées (widgets, historique, favoris, pièces jointes) sont en cours de construction.

## Pourquoi Triva

La plupart des assistants de recherche IA passent par le serveur d'une entreprise, qui voit tes questions. Triva fait l'inverse :

- **Aucun compte, aucune authentification.** Tu ouvres l'app et tu l'utilises.
- **Aucun serveur intermédiaire.** Ni chez le développeur, ni ailleurs — la recherche et la génération de réponse se font directement entre ton appareil et les services que tu as choisis.
- **Tu choisis qui traite tes données**, moteur par moteur. L'app t'indique toujours honnêtement où partent tes questions : « Sur l'appareil » n'est affiché que lorsque c'est vrai.

## Comment ça marche

### Moteur IA — 3 choix

1. **Apple Intelligence** — gratuit, tourne entièrement sur l'appareil (nécessite un appareil compatible).
2. **Modèle local (MLX)** — un modèle IA téléchargé une fois, puis exécuté hors ligne sur l'appareil. Triva propose un catalogue de 7 modèles Qwen3, du plus léger (0,6 milliard de paramètres) au plus puissant (32 milliards), et **te recommande celui qui convient à ton appareil** selon sa mémoire et sa puce. Une fois le modèle téléchargé, tu peux lui poser une ou deux questions d'essai avant de le valider.
3. **Ta propre clé API** (BYOK — *Bring Your Own Key*) — connecte le fournisseur cloud de ton choix avec ta propre clé : Anthropic (Claude), OpenAI, Google Gemini, Mistral, DeepSeek, xAI (Grok), Groq, OpenRouter, Perplexity, Together AI, Fireworks AI, Cerebras, ou tout service compatible que tu ajoutes toi-même. Facturé directement par le fournisseur, jamais par Triva.

Ta clé API n'est **jamais envoyée nulle part par Triva** : elle est stockée uniquement dans le Trousseau (Keychain) de ton appareil, et ne transite que vers le fournisseur que tu as choisi.

### Recherche

Quand tu poses une question, Triva :

1. **analyse ta question** pour décider quel type de recherche elle demande (web, académique, discussions), ou si elle n'a besoin d'aucune recherche ;
2. **interroge des instances SearXNG publiques** — un moteur de recherche open source qui ne t'espionne pas — avec bascule automatique si une instance ne répond pas ;
3. **lit les pages les plus utiles** en entier quand les extraits ne suffisent pas ;
4. **rédige une réponse** à partir de ces sources, affichée au fil de l'eau, avec la liste des sources consultées.

Tout ce travail d'analyse et de lecture tourne dans l'app elle-même.

## Où en est le projet

Triva se construit par versions. La **V0**, la fondation, est terminée. La **V1**, qui en fait un vrai produit, est écrite et intégrée : il reste à la vérifier sur le terrain et à la relire en profondeur avant de la déclarer terminée.

**Dans l'app (V1 intégrée)**
- Le choix du moteur IA (Apple Intelligence, MLX local, clé API perso), avec catalogue MLX, téléchargement et essai
- La configuration BYOK multi-fournisseurs, fournisseurs personnalisés compris
- La recherche de bout en bout : analyse de la question, recherche multi-étapes, tri fin des sources (une langue à la fois), lecture des pages, réponse en streaming
- Des réponses structurées avec citations numérotées cliquables, et le suivi de conversation
- Trois modes de réponse : Rapide, Approfondie, Fiable (sources de référence uniquement — sinon Triva le dit et propose de relancer en Rapide)
- Les widgets météo et calculatrice
- La recherche d'images et de vidéos, à la demande
- Des suggestions de questions de suivi
- Le fil d'actualités « Découvrir »
- L'historique des conversations et les favoris, stockés uniquement sur ton appareil
- Les pièces jointes : poser une question sur un PDF ou un fichier texte, sans qu'il quitte l'appareil
- L'affichage du raisonnement du modèle, quand il en produit un
- iPhone, iPad (barre latérale, plusieurs fenêtres) et Mac

**En cours (fin de V1)**
- La recherche avec ta propre clé Brave ou Tavily, et des sources ouvertes de secours (Wikipédia, OpenAlex, arXiv) quand les instances SearXNG publiques ne répondent pas
- Les essais sur le terrain et la relecture finale

## Configuration requise

- iPhone, iPad ou Mac sous **iOS 27 / iPadOS 27 / macOS 27**
- Pour Apple Intelligence : un appareil compatible Apple Intelligence
- Pour les modèles MLX : un appareil récent à puce Apple (les plus gros modèles demandent beaucoup de mémoire ; Triva te recommande ce que ton appareil peut faire tourner)
- Aucune autre inscription ni configuration serveur

## Confidentialité

- Aucune télémétrie, aucun tracking
- Aucune donnée envoyée à un serveur intermédiaire
- Les clés API restent en local, dans le Trousseau de ton appareil
- Uniquement des widgets qui ne demandent ni clé API ni compte — pas de service tiers caché derrière une fonctionnalité en apparence gratuite
