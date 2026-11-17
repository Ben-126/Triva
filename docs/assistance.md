<!-- À VALIDER -->
<!-- Brouillon du 2026-11-17 (mission T2). Version française : elle fait foi. Traduction anglaise : docs/en/support.md.
     Page « Support URL » d'App Store Connect (App Review Guidelines 1.5 : « an easy way to contact you »).
     Les commentaires « dépend de Mx » signalent une phrase vraie seulement après la mission Mx du plan légal : ne pas publier avant.
     Les emplacements entre crochets sont à remplir par l'éditeur : ne jamais y mettre de donnée personnelle d'un mineur. -->

# Assistance Triva

*Dernière mise à jour : [date de publication]*

## Nous contacter

Écris à **benpodro@gmail.com**. On répond dès que possible, en général sous quelques jours. Triva est faite par une petite équipe familiale, sans service client.

Dans ton message, indique si possible ton appareil (iPhone, iPad ou Mac), sa version du système, et la version de Triva (Réglages, tout en bas).

**Ne mets jamais ta clé API dans un e-mail.** Personne de chez Triva ne te la demandera.

## Signaler un problème ou un contenu

- **Une réponse fausse, choquante ou dangereuse** : dans Triva, Réglages > « Signaler un problème », ou écris à **benpodro@gmail.com**. Tu peux coller la question et la réponse, si tu veux : rien n'est envoyé sans toi.
- **Un bug** : décris ce que tu faisais, ce qui s'est passé et ce que tu attendais.
- **Un site ou un auteur** qui ne veut pas que Triva lise ses pages, ou qui pense qu'un de ses contenus est mal utilisé : écris-nous, on regarde rapidement.

Comme Triva n'a pas de serveur, l'éditeur ne voit pas tes conversations : il ne peut ni les retrouver, ni les corriger à distance.

## Questions fréquentes

### Est-ce que Triva est vraiment gratuite ?

Oui : pas de prix, pas de publicité, pas d'achat intégré, pas de compte. Les seuls frais possibles viennent des services que **tu** branches avec ta propre clé (une IA cloud, Brave, Tavily) : ils te facturent directement.

### Faut-il une clé API ?

Non. Sans aucune clé, Triva marche avec **Apple Intelligence** (sur les appareils compatibles) ou un **Modèle local (MLX)** que tu télécharges, et avec des moteurs de recherche gratuits.

Une clé sert seulement si tu veux utiliser une IA cloud (moteur « Clé API personnelle », écran « Clés API ») ou un service de recherche payant (écran « Clés de recherche » : Brave, Tavily). Tu crées la clé toi-même sur le site du fournisseur, et tu respectes ses conditions, **y compris son âge minimum** (Tavily : 18 ans).

### Où est gardée ma clé ? Qui la voit ?

Dans le **Trousseau** de ton appareil (le coffre-fort à mots de passe d'Apple). Elle part seulement vers le fournisseur concerné, directement depuis ton appareil. L'éditeur de Triva ne la voit jamais.

### Qu'est-ce que Triva fait de mes données ?

Rien qui passe par l'éditeur : **Triva n'a pas de serveur**, pas de pub, pas de statistiques, pas de pistage. Ton historique reste sur ton appareil. Pour répondre, Triva envoie ta question directement aux services nécessaires (moteurs de recherche, IA choisie). Tout est détaillé dans la [politique de confidentialité](confidentialite.md).

### Quelle est la différence entre les moteurs d'IA ?

- **Apple Intelligence, sur l'appareil** et **Modèle local (MLX)** : la réponse est écrite **sur ton appareil**. Ta question ne part vers aucune IA extérieure (la recherche web, elle, passe toujours par Internet).
- **Apple Intelligence, cloud privé d'Apple** : pour les demandes trop lourdes pour l'appareil, Apple peut les traiter sur ses serveurs sécurisés.
- **Clé API personnelle** : la réponse est écrite par le fournisseur cloud que tu as choisi, avec ta clé. Triva te demande ton accord avant le premier envoi. <!-- dépend de M2 -->

Le badge en haut de l'écran indique toujours quel moteur répond. <!-- emplacement du badge à vérifier sur iPhone, iPad et Mac (même réserve que ecrans.md B.1) -->

### Les modèles locaux (MLX) prennent beaucoup de place

Oui, de quelques centaines de Mo à plusieurs Go. Tu peux les supprimer dans Réglages > « Modèles MLX ». Ils sont téléchargés depuis Hugging Face.

### Comment tout effacer ?

Réglages, section « Données » > **« Tout effacer »** : ton historique, tes favoris et les caches sont supprimés de l'appareil. Tes clés, tes réglages et les modèles locaux sont gardés : supprime-les dans « Clés API », « Clés de recherche » et « Modèles MLX ». Ce que tu as déjà envoyé à un service extérieur doit être effacé chez lui. Détails : [politique de confidentialité, partie 7](confidentialite.md).

### C'est quoi, les « instances SearXNG » ?

SearXNG est un moteur de recherche libre que des bénévoles et des associations font tourner sur leurs propres serveurs (chaque serveur est une « instance »). Triva utilise par défaut des instances **publiques** et passe à une autre si l'une ne répond pas. Tu peux aussi ajouter ta propre instance dans Réglages > « Instances SearXNG ».

Pour garder une liste à jour, Triva télécharge de temps en temps l'annuaire public searx.space et teste quelques instances avec le mot « test » (jamais tes questions). Tu peux couper ça avec « Mettre à jour la liste automatiquement ». <!-- dépend de M13 -->

### La recherche ne marche pas ou est lente

Les instances publiques sont parfois saturées ou bloquent les apps. Réessaie un peu plus tard, ajoute une autre instance, ou utilise une clé Brave ou Tavily (Réglages > « Clés de recherche ») pour une recherche plus fiable.

### Pourquoi Triva ne lit pas certains sites ?

Certains sites demandent à ne pas être lus par des programmes automatiques, avec un fichier appelé `robots.txt`. Triva se présente honnêtement sous le nom « Triva » et **respecte ce refus** : elle ne lit pas ces pages, mais te donne quand même leur lien. <!-- dépend de M8 -->

D'autres sites bloquent toutes les apps, demandent un abonnement ou affichent leur contenu d'une façon que Triva ne sait pas lire. Ouvre le lien de la source pour voir la page dans ton navigateur.

### Pourquoi Triva ne lit pas un de mes PDF ?

Certains PDF sont **protégés contre la copie** par leur auteur. Triva lit un PDF protégé seulement s'il autorise l'extraction de son texte pour l'accessibilité (par exemple pour les lecteurs d'écran). Sinon, Triva ne le lit pas du tout, avec aucun moteur d'IA, et te prévient que ce fichier ne peut pas être lu. Il n'y a pas de réglage pour passer outre : c'est le choix de l'auteur du fichier. <!-- dépend de M10 -->

### Je vois des contenus pour adultes

Par défaut, Triva demande aux moteurs de recherche de filtrer ces contenus (niveau modéré). Vérifie que Réglages > « Avancé » > « Filtrer les contenus pour adultes » est activé. Aucun filtre n'est parfait : si un contenu choquant passe, signale-le.

### Triva m'a donné une réponse fausse

Ça peut arriver : une IA peut se tromper. Vérifie toujours les sources citées, et signale la réponse. Triva ne remplace pas un médecin, un avocat ou un conseiller financier.

## Pages utiles

- [Politique de confidentialité](confidentialite.md)
- [Conditions d'utilisation](conditions.md)
- [Mentions légales](mentions-legales.md)
- [Licences et attributions](licences.md)
- Code source de Triva : [adresse du dépôt] <!-- à compléter -->
