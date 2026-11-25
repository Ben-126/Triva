<!-- Version française : elle fait foi. Traduction : docs/en/privacy.md -->

# Politique de confidentialité de Triva

*Dernière mise à jour : 25 novembre 2026*

Cette page explique, simplement, ce que Triva fait de tes données. Elle est écrite pour être comprise par tout le monde, y compris si tu es au collège.

## En bref

- **Triva n'a pas de serveur.** L'éditeur de Triva ne reçoit, ne voit et ne garde **aucune** de tes questions, réponses ou clés. (Seule exception possible : des rapports de plantage anonymes transmis par Apple, si tu l'as accepté ; voir partie 10.)
- **Pas de compte, pas de publicité, pas de mesure d'audience, pas de pistage.** Triva ne contient aucun outil de statistiques ou de publicité.
- **Ce que tu fais dans Triva reste sur ton appareil** (iPhone, iPad ou Mac), sauf ce qu'il faut envoyer sur Internet pour répondre à ta question.
- Quand Triva envoie quelque chose sur Internet, c'est **directement** depuis ton appareil vers un service extérieur (un moteur de recherche, une IA que tu as choisie…). Ces services voient au moins l'**adresse IP** de ton appareil. Chacun applique ses propres règles. Ils sont tous listés plus bas.
- Le **widget**, la **recherche de l'appareil** (Spotlight), l'**activité en direct**, le **partage** vers Triva, **Siri** et **Raccourcis** travaillent sur ton appareil : Triva n'en envoie rien à son éditeur. Les trois premiers se règlent dans **Réglages > Intégrations**, et tu vois dans la partie 2 exactement ce qu'ils gardent.
- Tu peux effacer à tout moment ton historique, tes favoris, les caches et ce que Triva a publié dans le widget, la recherche de l'appareil et l'activité en direct, dans **Réglages > Données > Tout effacer** ; tes clés et les modèles locaux se suppriment dans leurs propres réglages (voir partie 7).

## 1. Qui publie Triva ?

Triva est publiée par **[Nom de l'éditeur]**, à titre non professionnel.

Contact pour toute question sur tes données : **benpodro@gmail.com**.

Triva est gratuite, sans publicité et sans achat intégré.

## 2. Ce qui reste sur ton appareil

Ces données sont enregistrées **uniquement sur ton appareil**. L'éditeur n'y a pas accès.

| Donnée | Où | Combien de temps |
|---|---|---|
| Historique : tes questions, les réponses, les sources trouvées | Base de données locale de l'app | Jusqu'à ce que tu la supprimes |
| Favoris | Base de données locale de l'app | Jusqu'à ce que tu les supprimes |
| Réglages (moteur IA choisi, fournisseur, modèle, tes instances de recherche, tes accords pour les IA cloud…) | Réglages de l'app (`UserDefaults`) | Jusqu'à ce que tu les changes ou supprimes l'app |
| Tes clés API (IA cloud, Brave, Tavily) | Trousseau de l'appareil (le coffre-fort à mots de passe d'Apple) | Jusqu'à ce que tu les supprimes dans Réglages > Clés API ou Clés de recherche |
| Liste des instances de recherche publiques et leur fiabilité mesurée | Stockage interne de l'app | Mise à jour au fil de l'usage |
| Caches (pages et réponses réseau récentes, contenu de l'onglet Découvrir) | Stockage interne de l'app | Renouvelés automatiquement ; vidés par « Tout effacer » |
| Modèles d'IA locaux (MLX) que tu as téléchargés | Stockage interne de l'app | Jusqu'à ce que tu les supprimes dans Réglages > Modèles MLX |
| Fichiers que tu joins à une question (choisis dans Fichiers, collés, glissés-déposés, pris dans la photothèque ou reçus par le partage) | Le fichier n'est pas envoyé ailleurs : son texte est lu sur ton appareil. Pour l'aperçu et le glisser-déposer, Triva garde une copie temporaire du fichier, uniquement sur ton appareil. Elle est effacée quand tu retires le fichier, commences une nouvelle conversation, fermes la fenêtre ou utilises “Tout effacer”, et au plus tard au prochain lancement de Triva. Pas de copie au-delà de 200 Mo (pas d'aperçu alors). Exception : une nouvelle question lancée depuis le widget, Siri ou le bouton Action garde les fichiers que tu avais joints sans les avoir encore envoyés (avec leur copie), pour ta première question. Pour une **image**, le texte est lu sur ton appareil (Vision) : l'image elle-même n'est jamais envoyée, et le texte reconnu suit la même règle que celui d'un PDF. Le **nom du fichier** et les **extraits** qui ont servi de sources à la réponse sont enregistrés avec elle dans l'historique (et dans les favoris si tu l'y ajoutes) | La copie : voir la règle à gauche. Le nom et les extraits : jusqu'à ce que tu supprimes la conversation ou le favori, ou « Tout effacer » |
| Pages que tu as fait lire avec « Lire cette page » | **En mémoire seulement** | Jusqu'à la fermeture de Triva ou « Tout effacer » |
| Données des sites ouverts dans le **navigateur intégré** (cookies, données de site) | iPhone et iPad : stockage du navigateur intégré (Safari), propre à Triva. Mac : **rien n'est gardé** | iPhone et iPad : jusqu'à ce que le site les efface, que tu utilises « Tout effacer » (qui les supprime aussi) ou que tu supprimes l'app |

**Protection.** Triva n'ajoute pas de chiffrement à elle : tes données sont protégées par la protection de ton appareil (code ou mot de passe, chiffrement intégré d'iPhone et d'iPad, FileVault sur Mac s'il est activé). Elles sont incluses dans les **sauvegardes** de ton appareil (iCloud ou ordinateur), comme les données des autres apps. Une exception : le dossier que Triva partage avec son widget et son extension de partage (voir 2.1) est un simple relais ; Triva demande au système de ne pas l'inclure dans les sauvegardes.

### 2.1 Widget, recherche de l'appareil, activité en direct, partage

Ces fonctions relient Triva au système de ton appareil. Elles ne passent par aucun serveur de l'éditeur. Les trois premières ont un réglage dans **Réglages > Intégrations**.

| Fonction | Ce qui est gardé, et où | Combien de temps |
|---|---|---|
| **Dernière question dans le widget** (éteint par défaut) | Un petit fichier dans un dossier partagé entre Triva et son widget (sur ton appareil) : le **titre** (80 caractères au plus), l'identifiant et la date de ta **dernière conversation**, jamais le texte d'une réponse ni plusieurs conversations. Tant que le réglage est éteint, ce fichier n'existe pas : le widget ne montre que le geste « Nouvelle question ». Le widget lit ce fichier, n'écrit rien et n'utilise pas Internet. Si tu l'ajoutes à l'écran verrouillé, le titre peut se lire sans déverrouiller l'appareil, sauf si tu as choisi dans iOS de masquer les contenus sensibles | Mis à jour quand ton historique change ; retiré tout de suite quand tu éteins le réglage ou utilises « Tout effacer » |
| **Historique dans la recherche de l'appareil** (allumé par défaut) | Le **titre** et la **date** de tes 500 conversations les plus récentes, dans l'index de recherche de ton appareil (Spotlight), qui reste sur l'appareil. Jamais le texte des questions ni des réponses. Triva note aussi dans ses réglages les identifiants de ce qu'elle a indexé (sans les titres), pour pouvoir le retirer | Retiré quand tu supprimes la conversation, éteins le réglage ou utilises « Tout effacer » |
| **Activité en direct pendant une recherche** (allumée par défaut ; iPhone et iPad) | Pendant une recherche, ta **question** (une ligne, 140 caractères au plus), l'étape (« Recherche… », « Lecture de 3 sources », « Rédaction… », « Réponse prête ») et le nombre de sources, sur l'écran verrouillé et dans la Dynamic Island. Elle ne démarre que si Triva est ouverte, se met à jour depuis l'appareil sans serveur ni notification push, et peut aussi s'afficher, selon tes appareils, sur une montre, un Mac ou CarPlay associés. Elle peut donc se lire sans déverrouiller l'appareil, sauf si tu as choisi dans iOS de masquer les contenus sensibles | Réponse prête et Triva ouverte : disparaît tout de suite. Réponse prête et Triva en arrière-plan : au plus 30 minutes. Recherche interrompue ou échouée : au plus 5 minutes. Retirée aussi quand tu éteins le réglage, supprimes la conversation, utilises « Tout effacer », ou au lancement suivant de Triva |
| **Partage vers Triva** (« Rechercher avec Triva » dans la feuille de partage ; iPhone et iPad) | Ce que tu partages (un texte, une adresse de page avec son titre, un PDF ou une image) est déposé dans un dossier partagé entre l'extension de partage et Triva, sur ton appareil : au plus 8 partages, 400 Mo de fichiers (PDF jusqu'à 200 Mo, image jusqu'à 50 Mo). Le texte est limité à 2 000 caractères et le nom du fichier est nettoyé. L'extension n'envoie rien sur Internet et ne lance aucune recherche. Au prochain passage de Triva au premier plan, le texte arrive dans la barre de saisie (jamais envoyé sans toi) et le fichier est joint à la question (copie temporaire, voir plus haut) | Effacé du dossier partagé dès que Triva l'a repris ; sinon périmé au bout de 24 heures et effacé au passage suivant de Triva ou de l'extension ; ou par « Tout effacer ». Le dossier de travail de l'extension (dossier temporaire) est effacé à la fin du partage ou, au plus tard, au partage suivant |

Sur Mac, il n'y a pas d'extension de partage, ni d'activité en direct. Le dossier partagé avec le widget n'est utilisé que si tu as allumé « Dernière question dans le widget » un jour.

**Siri et Raccourcis.** Les actions de Triva (« Poser une question à Triva », « Nouvelle recherche », « Chercher dans l'historique », « Ouvrir une conversation », « Choisir le mode de réponse ») ne gardent rien en plus de ce qui est décrit ici. Une question posée par Siri ou Raccourcis est enregistrée dans ton historique comme les autres. Les conversations vues par Siri et Raccourcis sont réduites à leur titre et leur date ; « Chercher dans l'historique » trouve aussi du texte de tes messages, mais ne rend que des titres et des dates, et demande de déverrouiller l'appareil. Voir aussi la partie 3.7.

**Coller et photothèque.** Coller un fichier ou une image (⌘V sur Mac, « Coller » dans le menu du trombone sur iPhone et iPad) ne lit le presse-papiers qu'au moment où tu le demandes. Pour une photo, Triva n'a pas accès à ta photothèque : c'est le sélecteur de photos du système qui s'ouvre, et Triva ne reçoit que les photos que tu y choisis. Un fichier collé ou une photo suivent ensuite la même règle que tout fichier joint (ligne « Fichiers que tu joins » ci-dessus).

## 3. Ce qui part sur Internet, et vers qui

Tous ces envois partent **directement de ton appareil**. Aucun ne passe par un serveur de l'éditeur. Chaque service reçoit au moins l'adresse IP de ton appareil et l'heure de la demande.

### 3.1 Automatiquement, sans que tu fasses rien

| Vers qui | Quand | Ce qui est envoyé |
|---|---|---|
| **searx.space** (annuaire des instances SearXNG publiques) | Quand tu ouvres Triva, au plus une fois par 24 heures (une heure après un échec de connexion) | Rien d'autre que la demande de la liste |
| **Quelques instances SearXNG publiques** | Quand la liste est téléchargée (pour vérifier les nouvelles instances), et à chaque ouverture de Triva pour retester au plus 3 instances qui marchaient mal | Une recherche de test, toujours le mot « test ». **Aucune de tes questions.** |

Tu peux couper ces vérifications avec le réglage **« Mettre à jour la liste automatiquement »** (Réglages > Avancé).

### 3.2 Quand tu poses une question

| Vers qui | Quand | Ce qui est envoyé |
|---|---|---|
| **Instances SearXNG** (publiques, ou celles que tu as ajoutées) | À chaque recherche | Ta question (parfois reformulée), la langue, le type de recherche, la page de résultats, la période ; filtre adulte « modéré » par défaut, désactivable dans Réglages > Avancé |
| **Sources ouvertes** : Wikipédia, OpenAlex, arXiv, Marginalia Search | Recherche, quand elles sont utiles | Les mots de ta recherche |
| **Brave Search** ou **Tavily** | Seulement si tu as saisi ta propre clé | Les mots de ta recherche et ta clé |
| **Les pages web trouvées** (n'importe quel site) | Pour lire les sources de la réponse | Une demande de la page, avec un nom qui identifie Triva. Pour cette lecture automatique, Triva respecte les sites qui la refusent (fichier `robots.txt`, ou signaux « noai » et « tdm-reservation » envoyés par la page). Si tu touches **« Lire cette page »** sur une source refusée, Triva la lit pour toi, comme un navigateur, sans appliquer ce refus. |
| **Open-Meteo** (météo) | Quand ta question porte sur la météo | Le nom de la ville que tu as tapé, puis ses coordonnées |
| **Hébergeurs des images et vignettes, YouTube** | Quand des résultats d'images ou de vidéos s'affichent | La demande de l'image (comme dans un navigateur) |

Triva ne garde, dans ton historique, que le **titre et le lien** des résultats Brave, comme l'exigent les conditions de Brave.

### 3.3 Le moteur d'IA qui écrit la réponse

Tu choisis toi-même le moteur dans les Réglages.

- **Apple Intelligence, sur l'appareil** et **Modèle local (MLX)** : la réponse est écrite sur ton appareil. Rien ne part vers une IA extérieure.
- **Apple Intelligence, cloud privé d'Apple** : quand la question dépasse ce que l'appareil sait faire, elle peut être traitée par le cloud privé d'Apple (Private Cloud Compute). D'après Apple, rien n'y est conservé. Voir la [politique de confidentialité d'Apple](https://www.apple.com/legal/privacy/).
- **Clé API personnelle** (IA cloud) : Triva envoie au fournisseur que tu as choisi, **avec ta clé** : ta question, les messages précédents de la conversation, des extraits des pages trouvées et le texte des fichiers que tu joins. Pour les recherches d'images et de vidéos, ta question lui est aussi envoyée pour être reformulée. Avant le premier envoi à chaque fournisseur, Triva te demande ton accord ; tu peux le retirer dans Réglages > Clés API.
- Les **PDF protégés contre la copie** ne sont lus que s'ils autorisent l'extraction de leur texte pour l'accessibilité. Sinon, Triva ne les lit pas du tout (ni sur ton appareil, ni dans le cloud) et te prévient.
- Certains fournisseurs (OpenAI, Claude, Perplexity) peuvent aussi **chercher sur le web** à partir de ta question, si tu actives ce mode ; c'est facturé sur ton compte chez eux.
- Pour afficher la liste des modèles ou vérifier ta clé, Triva contacte aussi ce fournisseur avec ta clé.

### 3.4 Quand tu télécharges un modèle local

Le modèle est téléchargé depuis **Hugging Face**, qui reçoit le nom du modèle demandé et ton adresse IP.

### 3.5 Quand tu ouvres un lien

Les liens s'ouvrent dans le **navigateur intégré** de Triva (Safari intégré sur iPhone et iPad, une fenêtre web sur Mac). Le site ouvert reçoit ce qu'il reçoit de n'importe quel navigateur (adresse IP, demande de la page) et peut déposer des cookies. Triva ne voit pas et ne garde pas ce que tu fais sur ces sites. Les règles du site s'appliquent. Sur iPhone et iPad, « Tout effacer » supprime aussi les cookies et les données de ces sites.

### 3.6 Quand tu ouvres l'onglet Découvrir

Triva télécharge les flux d'actualité de ces éditeurs : Numerama, Frandroid, The Conversation, ESPN, Variety, Deadline, The Hollywood Reporter, ARTnews. Ils reçoivent la demande du flux (et ton adresse IP). Les **images des articles** (sauf pour The Conversation) sont aussi téléchargées depuis les serveurs de ces éditeurs, ou ceux qui hébergent leurs images, qui reçoivent alors ton adresse IP.

### 3.7 Quand tu utilises Siri ou Raccourcis

Le widget, la recherche de l'appareil, l'activité en direct et le partage n'envoient rien sur Internet par eux-mêmes. « Poser une question à Triva » (Siri, Raccourcis) pose une vraie question : elle suit le même chemin qu'une question posée dans l'app (parties 3.2 et 3.3), avec le moteur d'IA que tu as choisi. Une question n'est jamais envoyée à une IA cloud sans ton accord pour ce fournisseur : sinon Triva te demande d'ouvrir l'app, et ta question attend dans la barre de saisie. Triva rend à Siri ou Raccourcis (Apple) ta question, la réponse, et le titre et le lien des sources ; ce qu'un raccourci fait ensuite de ces éléments dépend du raccourci que tu as construit. Siri et Raccourcis sont des services d'Apple, qui applique ses propres règles (voir la [politique de confidentialité d'Apple](https://www.apple.com/legal/privacy/)).

## 4. Les services extérieurs suivent leurs propres règles

Les services de la partie 3 ne sont pas contrôlés par l'éditeur de Triva. Chacun décide de ce qu'il garde, combien de temps et dans quel pays, selon sa propre politique. Certains sont situés **hors de l'Union européenne**, par exemple aux États-Unis ; **DeepSeek indique conserver les données en Chine**. Certains fixent un **âge minimum** : par exemple, Tavily est réservé aux personnes de 18 ans ou plus.

Pour les services que tu choisis avec **ta propre clé** (IA cloud, Brave, Tavily), c'est toi qui as un compte chez eux : leurs conditions s'appliquent à toi directement.

Politiques de confidentialité (adresses vérifiées le 14 novembre 2026) :

| Service | Politique |
|---|---|
| OpenAI | https://openai.com/policies/eu-privacy-policy/ (cette politique ne couvre pas les contenus envoyés par l'API : ce sont les conditions d'OpenAI pour les entreprises qui s'appliquent, voir https://openai.com/policies/) |
| Claude (Anthropic) | https://www.anthropic.com/legal/privacy |
| Google Gemini | https://policies.google.com/privacy et https://ai.google.dev/gemini-api/terms (avec une clé gratuite, Google peut utiliser tes envois pour améliorer ses produits) |
| Perplexity | https://www.perplexity.ai/hub/legal/privacy-notice |
| Groq | https://groq.com/privacy-policy |
| OpenRouter | https://openrouter.ai/privacy (transmet ensuite tes envois à l'entreprise qui fait tourner le modèle choisi) |
| Mistral | https://legal.mistral.ai/terms/privacy-policy |
| DeepSeek | https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html |
| xAI (Grok) | https://x.ai/legal/privacy-policy |
| Together AI | https://www.together.ai/privacy |
| Fireworks AI | https://fireworks.ai/privacy-policy |
| Cerebras | https://www.cerebras.ai/privacy-policy |
| Brave Search | https://api-dashboard.search.brave.com/privacy-policy |
| Tavily | https://www.tavily.com/privacy |
| Apple | https://www.apple.com/legal/privacy/ |
| Hugging Face | https://huggingface.co/privacy |
| Open-Meteo | https://open-meteo.com/en/terms |
| Wikipédia (Wikimedia) | https://foundation.wikimedia.org/wiki/Policy:Privacy_policy |
| arXiv | https://info.arxiv.org/help/policies/privacy_policy.html |
| Marginalia Search | https://about.marginalia-search.com/article/privacy/ |
| OpenAlex | https://openalex.org/privacy |
| searx.space et instances SearXNG | Chaque instance est gérée par une personne ou une association différente, avec ses propres règles. Liste : https://searx.space/ |

Si tu ajoutes un **fournisseur personnalisé** ou ta **propre instance** de recherche, c'est toi qui le choisis : Triva ne connaît pas ses règles.

## 5. Pourquoi ces envois sont faits

- Pour **répondre à ta question** : c'est le service que tu demandes à Triva.
- Pour **garder la recherche fiable** (liste et test des instances) : sans ça, beaucoup de recherches échoueraient. Tu peux couper cette fonction.

**Bases légales** (article 6 du RGPD) :

- les envois nécessaires pour répondre à ta question reposent sur l'**exécution du service** que tu demandes en utilisant Triva (voir les [conditions d'utilisation](conditions.md)) ;
- la mise à jour et le test des instances reposent sur l'**intérêt légitime** à garder la recherche fiable ; tu peux t'y opposer en coupant le réglage « Mettre à jour la liste automatiquement » ;
- l'envoi à une IA cloud repose sur ton **accord**, que tu peux retirer à tout moment dans Réglages > Clés API.

Tu n'es pas obligé d'utiliser ces services : sans IA cloud ni clé, Triva marche avec Apple Intelligence ou un modèle local.

## 6. Le rôle de l'éditeur

L'éditeur ne reçoit aucune de tes données. Mais c'est lui qui a conçu Triva et choisi les services utilisés par défaut (instances publiques, sources ouvertes, mises à jour automatiques). **Par prudence, il se comporte comme le responsable de ces choix** au sens du règlement européen sur la protection des données (RGPD) : il t'informe ici, il répond à tes questions, et il ne collecte rien.

Pour les envois que tu décides toi-même avec ta propre clé ou ton propre service, chaque fournisseur est responsable de ce qu'il fait de tes données.

## 7. Effacer tes données

- **Tout effacer** (Réglages, section « Données ») supprime d'un coup, sur cet appareil : ton historique (conversations, messages, sources), tes favoris, le cache réseau, le cache de l'onglet Découvrir, les copies temporaires de fichiers joints, ce que Triva a publié dans le widget, dans la recherche de l'appareil et dans l'activité en direct, les partages en attente (iPhone et iPad) et, sur iPhone et iPad, les cookies et données des sites ouverts dans le navigateur intégré. Normalement, la base de données est entièrement vidée et il n'en reste pas de trace. Si ce n'est pas possible, Triva supprime les éléments un par un (avec les mêmes traces temporaires qu'une conversation supprimée seule, voir plus bas) et te dit si une partie n'a pas pu être effacée.
- « Tout effacer » **ne supprime pas** : tes clés API, le moteur, le fournisseur et le modèle choisis, tes accords pour les IA cloud, tes instances de recherche, tes autres réglages (dont les trois de « Intégrations »), les modèles locaux téléchargés. Pour les supprimer : Réglages > Clés API (ou Clés de recherche), et Réglages > Modèles MLX.
- **Éteindre** « Dernière question dans le widget » ou « Historique dans la recherche de l'appareil » retire tout de suite ce que Triva avait publié ; éteindre « Activité en direct » arrête celle en cours. Si le système refuse un retrait, Triva réessaie quelques fois, et « Tout effacer » te prévient quand quelque chose n'a pas pu être effacé.
- Une **conversation supprimée seule** disparaît tout de suite de l'app (et de la recherche de l'appareil ; son activité en direct terminée est retirée). Elle peut rester un temps dans le fichier interne de la base, toujours protégé par le chiffrement de ton appareil, jusqu'au nettoyage automatique de ce fichier.
- **Supprimer l'app** supprime ses données de l'appareil. Les clés enregistrées dans le Trousseau peuvent parfois rester après la suppression de l'app : supprime-les d'abord dans les Réglages de Triva.
- Les **données des sites ouverts dans le navigateur intégré** (cookies) : sur Mac, rien n'est gardé ; sur iPhone et iPad, « Tout effacer » les supprime aussi (supprimer l'app les efface également).
- Ce que tu as **déjà envoyé** à un service extérieur (partie 3) ne peut pas être effacé par Triva : demande-le directement à ce service. Il en va de même de ce qu'un raccourci que tu as construit a enregistré ailleurs (une note, un fichier…).

## 8. Tes droits

Le RGPD te donne des droits sur tes données : y **accéder**, les **corriger**, les **effacer**, t'**opposer** à un traitement, **limiter** un traitement, les **récupérer** (portabilité), et **retirer ton accord** à tout moment.

- Pour les données **sur ton appareil**, tu exerces ces droits toi-même dans l'app : tu les vois, tu les supprimes, tu retires tes accords.
- Pour les données envoyées à un **service extérieur**, adresse-toi à ce service (liens de la partie 4).
- Pour toute question, écris à l'éditeur : **benpodro@gmail.com**. Comme l'éditeur ne détient aucune de tes données, il ne peut ni te les envoyer ni les effacer à ta place, mais il t'aidera à savoir à qui t'adresser.
- Tu peux aussi faire une **réclamation auprès de la CNIL** (l'autorité française de protection des données) : https://www.cnil.fr/fr/plaintes. Si tu vis dans un autre pays, tu peux aussi t'adresser à l'autorité de protection des données de ton pays.

## 9. Si tu as moins de 15 ans

En France, avant 15 ans, certaines utilisations de tes données demandent l'accord d'un de tes parents en plus du tien (loi Informatique et Libertés, article 45). Pour Triva, cela concerne surtout les **IA cloud** : si tu as moins de 15 ans, accepte l'envoi à un fournisseur **avec un de tes parents**. Vérifie aussi l'âge minimum demandé par chaque service (partie 4) : certains, comme Tavily, sont réservés aux adultes.

## 10. Ce que Triva ne fait pas

- Pas de compte ni d'inscription.
- Pas de publicité.
- Pas de mesure d'audience ni de statistiques d'usage. Triva n'envoie elle-même aucun rapport d'erreur. Si tu as activé, dans les réglages de ton appareil, le partage des analyses avec les développeurs, Apple peut transmettre à l'éditeur des rapports de plantage sans ton identité.
- Pas de pistage entre apps ou sites, pas d'identifiant publicitaire.
- Pas de décision automatisée te concernant : Triva ne prend aucune décision à ton sujet qui aurait des effets juridiques ou t'affecterait de façon importante (RGPD, article 22).
- Pas de vente ni de partage de données par l'éditeur : il n'en a aucune.
- Pas d'accès à ta position, à tes contacts, à ton micro ni à ta caméra, et pas d'accès à l'ensemble de ta photothèque : pour joindre une photo, tu la choisis dans le sélecteur du système, et Triva ne reçoit que celles-ci. Triva ne lit que les fichiers, images et textes que tu choisis toi-même de joindre, de coller ou de partager vers Triva. Triva peut demander l'accès au **réseau local**, seulement si tu ajoutes une instance de recherche hébergée chez toi.

## 11. Changements de cette politique

Si Triva change sa façon de traiter tes données, cette page sera mise à jour et sa date changera. Si un changement concerne ce qui est envoyé à une IA cloud, Triva te redemandera ton accord dans l'app.

## Historique des versions

| Version | Date | Changements |
|---|---|---|
| 1.0 | 18 novembre 2026 | Première version. |
| 1.1 | 25 novembre 2026 | Ajout du widget, de la recherche de l'appareil (Spotlight), de l'activité en direct, du partage vers Triva, de Siri et Raccourcis, du collage et de la photothèque (parties 2.1, 3.7, 7 et 10) ; règle d'effacement des copies temporaires de fichiers. |
