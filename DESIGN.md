# Triva — Direction artistique (DA)

**Statut : validée par Ben le 2026-08-30.**

Ce fichier est la référence unique de la DA de Triva. **Avant d'écrire ou de modifier
une vue SwiftUI, le lire et vérifier que le code produit y est conforme.**

Implémentation de référence (code réel, compile, previews à jour) :
`Triva/DesignSystem/TrivaHomeReferenceView.swift`. En cas de doute entre ce document et
le code de référence, le code de référence fait foi (il est vérifié par compilation, pas
ce fichier).

Skills à respecter en complément : `swiftui-design-principles` (restraint, grille
d'espacement, couleurs sémantiques) et `liquid-glass-design` (usage du verre iOS 26).

---

## Règle absolue : ça ne doit jamais "faire IA"

Triva ne doit **jamais** avoir l'air d'une app générée par IA. C'est une exigence de
Ben, non négociable — à vérifier sur chaque écran avant de le considérer fini.

Signaux à bannir systématiquement :

- Dégradés de fond décoratifs, glow, "aurora background"
- Emoji dans l'UI (icônes SF Symbols uniquement, voir plus bas)
- Cartes à coins arrondis + liseré coloré sur le bord gauche (le cliché "AI dashboard")
- Polices surexploitées par les générateurs IA (Inter, Roboto, Arial, Fraunces) — cette
  DA n'utilise que la police système (SF), c'est aussi pour ça
- Remplissage : stats/chiffres/icônes qui ne servent à rien, sous-titre qui répète le
  titre, copy générique ("Bienvenue dans votre assistant IA...")
- Emojis ou ton "startup IA" dans le copywriting — rester factuel et sobre

Le test : une vue doit ressembler à ce que ferait une équipe design Apple en interne,
pas à un template. En cas de doute sur un écran, comparer avec
`Triva/DesignSystem/TrivaHomeReferenceView.swift` et avec ce document — pas avec des
réflexes "par défaut" d'outil de génération.

---

## Principe

Langage visuel clair et épuré, proche d'Apple pur (SF, Liquid Glass discret), avec un
seul ajout thématique : mettre en avant la confidentialité ("sur l'appareil") **quand
c'est vrai**, et seulement dans ce cas.

C'est un mix des pistes explorées A (Apple pur) et B (sombre/confidentiel), tirant
volontairement plus vers A. B, C et D ont été écartées — leurs maquettes restent dans
`Triva/DesignExploration/` à titre d'archive, ce dossier n'est pas versionné (voir
`.gitignore`) et ne doit jamais l'être : ce sont des essais, pas la DA.

## Couleurs

- **Un seul accent** : l'asset `AccentColor` (`Triva/Assets.xcassets/AccentColor.colorset`)
  — bleu système, `#007AFF` en clair / `#0A84FF` en sombre. Toujours utiliser
  `Color.accentColor` / `.tint` / `.foregroundStyle(.tint)`, **jamais** `.blue` ou un hex
  écrit en dur dans une vue.
- Le reste : couleurs sémantiques système uniquement — `.primary`, `.secondary`,
  `.tertiary`. Pas de fond forcé (`Color(.systemBackground)` n'existe pas en
  multiplateforme iOS/macOS et casse le build macOS — laisser le fond par défaut du
  conteneur système).
- Pas de mode sombre forcé (sauf raison délibérée et documentée) — adaptation
  automatique via les couleurs sémantiques.
- Opacités limitées à 2-3 valeurs avec un rôle clair (ex. `0.15` pour un fond de badge
  teinté). Ne pas empiler des dizaines d'opacités différentes.

## Typographie

- Police système uniquement, design `.default` partout sur cette DA (pas de
  `.rounded`/`.serif`/`.monospaced` — réservés aux pistes écartées).
- Échelle utilisée (5 tailles, pas plus par écran) :
  | Rôle | Taille / style |
  |---|---|
  | Titre d'accroche | 28pt, `.semibold` |
  | Accroche secondaire ("Bonjour") | `.subheadline`, `.secondary` |
  | Badge moteur IA | `.footnote`, `.medium` |
  | Légende de confidentialité | `.caption`, `.tertiary` |
  | Label de section (ex. "ESSAIE") | 11pt `.medium`, `tracking(1.5)`, majuscules, `.tertiary` |
- Tracking limité à ces mêmes 1-2 valeurs, jamais 3+.

## Espacement

Grille stricte : `4, 8, 12, 16, 20, 24, 32, 40`. Aucune valeur arbitraire.

- Padding horizontal du contenu : 20
- Entre sections majeures (accroche / recherche / suggestions) : 32
- À l'intérieur d'un groupe (champ + badge, badge + légende) : 12 / 6
- Chips / boutons : 8 entre eux

## Liquid Glass (iOS 26)

- Barre de recherche : `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))`
- Badges / chips : `.glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)`
- Boutons de suggestion / actions secondaires : `.buttonStyle(.glass)`
- Actions principales (CTA) : `.buttonStyle(.glassProminent)`
- **Toujours** envelopper des éléments de verre frères dans un `GlassEffectContainer`
  (perf + morphing cohérent).
- `.interactive()` uniquement sur ce qui répond réellement au toucher.
- Ne pas mettre du verre partout — réservé aux barres, badges/cartes et boutons
  interactifs, jamais en fond plein écran ni sur du texte statique.
- **Rayon de coin** : deux formes seulement dans toute l'app — `.capsule` pour les
  badges/chips/petits boutons, `.rect(cornerRadius: 20)` pour tout conteneur plus grand
  (barre de recherche, carte de sélection, panneau de résultat). Ne pas introduire
  d'autres rayons (8, 12, 16...) — c'est ce qui garde le vocabulaire de formes cohérent
  dans toute l'app.
- Une carte sélectionnable (choix de moteur, choix de modèle) utilise
  `.glassEffect(.regular.tint(.accentColor.opacity(0.12)))` quand sélectionnée,
  `.glassEffect(.regular)` sinon — jamais de bordure `.stroke` en plus, la teinte suffit
  à indiquer la sélection.

## Icônes

SF Symbols uniquement (`Image(systemName:)`). Jamais d'emoji dans l'UI.

## Ton et copywriting

- Français, tutoiement, phrases courtes ("Bonjour", "Que veux-tu explorer ?").
- Pas de remplissage : chaque texte a un rôle, pas de sous-titre qui répète le titre.

## Badge moteur IA — règle de confidentialité

Sur tout écran qui utilise l'IA, un badge indique le moteur actif
(`AIEngineOption`, voir `Triva/Core/AI/AIProviderSelector.swift`). Son contenu **doit
refléter la vérité selon le moteur**, jamais un texte figé :

| Moteur | Icône | Texte | Légende |
|---|---|---|---|
| `.appleIntelligence` | `lock.fill` | "Apple Intelligence · Sur l'appareil" | "Aucune donnée envoyée à un serveur" |
| `.mlxLocal` | `lock.fill` | "Modèle local (MLX) · Sur l'appareil" | "Aucune donnée envoyée à un serveur" |
| `.cloudBYOK` | `key.fill` | "Clé API personnelle" | "Envoyé directement à ton fournisseur — jamais à un serveur Triva" |

La mention "sur l'appareil" ne doit **jamais** apparaître pour `.cloudBYOK` : c'est faux
dans ce cas (les données quittent l'appareil vers le fournisseur choisi), même si aucun
serveur Triva n'est jamais impliqué (règle "zéro backend" du projet, valable pour les
3 moteurs).

## Composants de référence

Tous implémentés dans `Triva/DesignSystem/TrivaHomeReferenceView.swift` :

- Barre de recherche en verre (icône loupe + `TextField`)
- Badge moteur IA + légende de confidentialité (voir tableau ci-dessus)
- Chips de suggestions (`ScrollView(.horizontal)`, `.buttonStyle(.glass)`)

## Comment vérifier une nouvelle vue avant de la committer

1. Couleurs : sémantiques ou `.accentColor` uniquement — aucun hex/`.blue` en dur.
2. Espacement : uniquement des valeurs de la grille (4/8/12/16/20/24/32/40).
3. Badge moteur IA (si présent) : correspond-il au vrai `AIEngineOption` sélectionné et
   au tableau ci-dessus ?
4. Verre : utilisé avec parcimonie, dans un `GlassEffectContainer` si plusieurs éléments,
   `.interactive()` seulement sur l'interactif.
5. Checklist des skills `swiftui-design-principles` et `liquid-glass-design` respectée.
