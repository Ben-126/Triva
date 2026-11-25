# Triva

Triva est un moteur de recherche IA **privé et natif** pour iPhone, iPad et Mac. Pas de compte, pas de serveur : tout tourne sur ton appareil ou passe directement par les fournisseurs que **toi** tu choisis.

> ⚠️ **Projet en développement actif.** Triva n'est pas encore disponible sur l'App Store. Le cœur de l'app — poser une question, obtenir une réponse sourcée, avec historique, favoris et pièces jointes — fonctionne déjà ; les fonctions qui l'intègrent au système (iPhone Duo, Mac approfondi, widget, Siri, partage…) sont en cours de construction ou de vérification sur appareil.

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
2. **cherche des sources**, en passant à la suivante tant qu'il n'y a ni réponse ni résultat :
   1. ta **clé de recherche personnelle**, si tu en as ajouté une : Brave Search, puis Tavily ;
   2. des **instances SearXNG publiques** — un moteur de recherche open source qui ne t'espionne pas — avec bascule automatique si une instance ne répond pas ;
   3. la **recherche web de ton fournisseur IA**, seulement avec le moteur « Clé API personnelle », si ton fournisseur en propose une (il te la facture) ;
   4. des **sources ouvertes, sans clé** : Wikipédia, OpenAlex, arXiv et Marginalia, selon le type de question ;
3. **lit les pages les plus utiles** en entier quand les extraits ne suffisent pas ;
4. **rédige une réponse** à partir de ces sources, affichée au fil de l'eau, avec la liste des sources consultées.

Tout ce travail d'analyse et de lecture tourne dans l'app elle-même. Quand les résultats ne viennent pas de SearXNG, une ligne sous les sources dit quel service les a fournis. Si aucune source ne répond, Triva te le dit et te propose d'ajouter une clé.

**Clé Brave ou Tavily (facultatif).** Une clé personnelle donne des résultats plus fiables que les instances publiques, quel que soit ton moteur IA. Tes recherches partent alors d'abord chez ce service, directement. Tu l'ajoutes dans Réglages > Recherche > Clés de recherche : Triva la teste avant de l'enregistrer dans le Trousseau de ton appareil, et chaque test consomme une requête de ton quota.

## Où en est le projet

Triva se construit par versions. La **V0**, la fondation, est terminée. La **V1**, qui en fait un vrai produit, est terminée. La **V2**, qui exploite ce que seule une app native permet, est en cours.

**Dans l'app (V1)**
- Le choix du moteur IA (Apple Intelligence, MLX local, clé API perso), avec catalogue MLX, téléchargement et essai
- La configuration BYOK multi-fournisseurs, fournisseurs personnalisés compris
- La recherche de bout en bout : analyse de la question, recherche multi-étapes, tri fin des sources (une langue à la fois), lecture des pages, réponse en streaming
- La recherche avec ta propre clé Brave ou Tavily, et des sources de secours (recherche de ton fournisseur IA, Wikipédia, OpenAlex, arXiv, Marginalia) quand les instances SearXNG publiques ne répondent pas
- Des réponses structurées avec citations numérotées cliquables, et le suivi de conversation
- Trois modes de réponse : Rapide, Approfondie, Fiable (sources de référence uniquement — sinon Triva le dit et propose de relancer en Rapide)
- Les widgets météo et calculatrice
- La recherche d'images et de vidéos, à la demande
- Des suggestions de questions de suivi
- Le fil d'actualités « Découvrir »
- L'historique des conversations et les favoris, stockés uniquement sur ton appareil
- Les pièces jointes : poser une question sur un PDF, un document Word (.docx) ou un fichier texte, sans qu'il quitte l'appareil
- L'affichage du raisonnement du modèle, quand il en produit un
- iPhone, iPad (barre latérale, plusieurs fenêtres) et Mac
- Un usage honnête de l'IA et du web : un écran explique dès le premier lancement que les réponses sont écrites par une IA, chaque réponse porte un avertissement, et le texte copié ou partagé reste marqué « généré par IA ». Triva se présente sous son nom aux sites qu'elle lit et respecte ceux qui refusent la lecture automatique (`robots.txt`)
- Avant le premier envoi à une IA en ligne, une feuille dit exactement ce qui part et chez qui, et Triva demande ton accord
- Dans les Réglages : la confidentialité, les conditions d'utilisation, les mentions légales, les licences de tous les logiciels, modèles et sources utilisés, et un bouton « Signaler un problème »

**V2 en cours : ce qu'une app native permet et pas le web**
- L'iPhone Duo : en plié, l'écran s'adapte à la place disponible et un bouton ferme le clavier ; en déplié et en paysage, la conversation et ses sources s'affichent côte à côte (les Favoris aussi : liste et détail). Le brouillon, la position de lecture et la réponse en cours sont gardés quand on plie ou déplie
- Le Mac approfondi : une recherche par fenêtre, les menus et raccourcis clavier complets, « Rechercher avec Triva » depuis n'importe quelle app (Services), une barre des menus et un menu du Dock en option, le glisser-déposer de fichiers et d'images (texte lu sur l'appareil) dans les deux sens, et Coup d'œil sur les pièces jointes (aussi sur iPad et iPhone)
- L'intégration au système, codée mais encore à vérifier sur appareil réel :
  - un **widget** « Recherche rapide » (iPhone, iPad, Mac, écran verrouillé) et une commande « Nouvelle question » (Centre de contrôle, bouton Action). Le widget peut afficher le titre de ta dernière conversation, **seulement si tu l'actives** dans Réglages > Intégrations (éteint par défaut : rien n'est alors écrit pour lui) ;
  - ton historique (titres et dates, **jamais le texte des réponses**) dans **Spotlight**, réglable et allumé par défaut ;
  - une **activité en direct** pendant une recherche (écran verrouillé, Dynamic Island ; iPhone et iPad), réglable et allumée par défaut : elle montre l'étape (réflexion, sources, rédaction) et, si le réglage « Afficher la question » est allumé (par défaut), ta question, qui peut alors se lire sans déverrouiller l'appareil ;
  - le **partage** vers Triva depuis la feuille de partage (iPhone et iPad) : un texte, une page web, un PDF, un document Word (.docx) ou une image arrivent dans la barre de saisie ou en pièce jointe, jamais envoyés sans toi ;
  - **Siri et Raccourcis** : poser une question, ouvrir une nouvelle recherche, chercher dans l'historique, ouvrir une conversation, choisir le mode de réponse ; une question ne part jamais vers une IA en ligne sans ton accord pour ce fournisseur ;
  - **coller** une image ou un fichier, et joindre des photos choisies dans la **photothèque** (le sélecteur du système : Triva ne voit que les photos choisies).
- À venir : la voix, la synchronisation iCloud et la traduction en anglais et en espagnol

**Plus tard**
- La publication sur l'App Store

## Configuration requise

- iPhone, iPad ou Mac sous **iOS 27 / iPadOS 27 / macOS 27**
- Pour Apple Intelligence : un appareil compatible Apple Intelligence
- Pour les modèles MLX : un appareil récent à puce Apple (les plus gros modèles demandent beaucoup de mémoire ; Triva te recommande ce que ton appareil peut faire tourner)
- Aucune autre inscription ni configuration serveur

## Confidentialité

- Aucune télémétrie, aucun tracking
- Aucune donnée envoyée à un serveur intermédiaire
- Les clés API et les clés de recherche restent en local, dans le Trousseau de ton appareil
- Uniquement des widgets de réponse (météo, calculatrice) qui ne demandent ni clé API ni compte — pas de service tiers caché derrière une fonctionnalité en apparence gratuite
- Le widget, Spotlight, l'activité en direct et le partage restent sur ton appareil : ils n'envoient rien sur Internet et rien à l'éditeur
- Pour l'aperçu et le glisser-déposer, Triva garde une copie temporaire du fichier joint, uniquement sur ton appareil, effacée quand tu retires le fichier, commences une nouvelle conversation, fermes la fenêtre ou utilises « Tout effacer », et au plus tard au prochain lancement de Triva
- « Tout effacer » (Réglages > Données) supprime d'un coup l'historique, les favoris, les caches, les copies temporaires de fichiers, ce que Triva avait publié dans le widget et Spotlight, et les données du navigateur intégré

Le détail est dans la [politique de confidentialité](docs/confidentialite.md) ([English](docs/en/privacy.md)), avec les [conditions d'utilisation](docs/conditions.md), les [mentions légales](docs/mentions-legales.md), les [licences et attributions](docs/licences.md) et l'[assistance](docs/assistance.md).

## License

Ce projet est sous licence MIT - voir le fichier [LICENSE](LICENSE) pour plus de détails.