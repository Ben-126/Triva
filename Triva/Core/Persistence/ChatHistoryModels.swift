//
//  ChatHistoryModels.swift
//  Triva
//
//  Created by ben podrojsky on 24/09/2026.
//

import Foundation
import SwiftData

// MARK: - Isolation : pourquoi `nonisolated` sur les `@Model`
//
// L'app compile avec `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
// (`-default-isolation=MainActor`) : tout type non annoté devient
// implicitement `@MainActor`. La question se pose donc pour chaque `@Model`.
//
// Ce que fait réellement la macro `@Model` (constaté en lisant son expansion,
// pas supposé) : elle génère elle-même
//
//     extension StoredConversation: nonisolated SwiftData.PersistentModel {}
//     extension StoredConversation: nonisolated Observation.Observable {}
//     @available(*, unavailable, message: "PersistentModels are not Sendable…")
//     extension StoredConversation: Sendable {}
//
// Trois conséquences, chacune vérifiée par compilation d'un cas réduit :
//
// 1. Les conformances sont déjà NON isolées. `PersistentModel` hérite de
//    `SendableMetatype` (voir l'interface du SDK), et une conformance isolée ne
//    pourrait pas le satisfaire — mais la macro a déjà réglé ce point. Passer
//    `StoredConversation.self` à `Schema(_:)` compile donc dans les deux cas.
// 2. `nonisolated` n'est PAS nécessaire pour compiler. Un `@Model` laissé sans
//    annotation compile aussi, et ses propriétés persistées restent lisibles
//    depuis un contexte non isolé (les accesseurs générés par
//    `@_PersistedProperty` ne sont pas isolés). On l'écrit quand même, voir
//    ci-dessous — mais on ne prétend pas que le compilateur l'exige.
// 3. Ces classes ne sont explicitement PAS `Sendable` : la conformance est
//    déclarée `unavailable`. C'est LÀ qu'est la vraie garantie, et elle est
//    tenue par le compilateur : toute tentative de faire traverser une
//    instance vers un autre domaine d'isolation est rejetée.
//
// Pourquoi l'écrire alors : parce que la consigne du projet est de ne pas
// laisser le compilateur arbitrer par accident. `nonisolated` s'applique aux
// membres que NOUS écrivons ici (les `init`, `orderedMessages`, `role`,
// `orderedSources`) et les range du bon côté — ce sont de la donnée pure et du
// tri déterministe, pas de l'état d'interface. Le laisser implicite ferait
// dépendre leur isolation d'un détail d'expansion de macro qui peut changer.
//
// La règle d'usage, elle, est explicite et tenue par `ChatHistoryStore` : **tout
// accès à ces modèles se fait depuis le `@MainActor`**, parce que le seul
// `ModelContext` de l'app est le `mainContext`, que le SDK déclare
// `@MainActor`.
//
// Alternative écartée : un `@ModelActor` dédié pour écrire hors du main actor.
// Rejetée pour V1 parce que (1) les volumes sont minuscules — une conversation
// fait quelques dizaines de messages ; (2) un `@ModelActor` ne peut renvoyer
// que des `PersistentIdentifier`, puisque les modèles ne sont pas `Sendable`,
// ce qui obligerait chaque appelant à refetcher côté UI ; (3) les vues SwiftUI
// ont de toute façon besoin d'instances liées au `mainContext`. À rouvrir si un
// import massif apparaît (V2).

// MARK: - Conversation

/// Une conversation sauvegardée localement (racine de l'historique, 1.9).
///
/// Portage de la table `chats` de `src/lib/db/schema.ts` (web, drizzle/SQLite),
/// dont les colonnes sont `id`, `title`, `createdAt`, `sources` et `files`.
/// Trois écarts assumés :
/// - le web stocke `sources` et `files` **au niveau du chat**, en colonnes JSON
///   (`$type<SearchSources[]>`, `$type<DBFile[]>`) ; ici les sources
///   appartiennent au MESSAGE qui les cite, ce qui est la vérité du produit
///   (chaque réponse a ses propres sources numérotées, voir `CitationParser`)
///   et évite de réécrire un gros blob JSON à chaque tour de conversation ;
/// - le web n'a que `createdAt`, aucune date de mise à jour ; on ajoute
///   `updatedAt`, indispensable pour trier la Library par activité récente et
///   non par date de création (relancer une vieille conversation doit la faire
///   remonter en tête) ;
/// - `id` est un `UUID` propre au modèle, en plus du `persistentModelID`
///   interne à SwiftData : il survit à un export/réimport et donne aux Favoris
///   (1.10) une clé stable à référencer.
///
/// Pas de `@Attribute(.unique)` sur `id` : une contrainte d'unicité SwiftData
/// transforme une insertion en *upsert* silencieux, ce qui écraserait une
/// conversation existante au lieu de lever une erreur. On préfère l'absence de
/// contrainte à un écrasement invisible — les UUID sont générés ici, jamais
/// saisis par un tiers.
@Model
nonisolated final class StoredConversation {
    /// Identifiant stable et portable de la conversation.
    var id: UUID

    /// Titre affiché dans la Library. Dérivé de la première question par
    /// `ConversationTitleBuilder`, renommable par l'utilisateur.
    var title: String

    /// Date du premier message. Jamais modifiée après création.
    var createdAt: Date

    /// Date de la dernière écriture (ajout ou modification d'un message,
    /// renommage). C'est le critère de tri de la Library.
    var updatedAt: Date

    /// Messages de la conversation, **non ordonnés** : un tableau de relation
    /// SwiftData n'a pas d'ordre garanti. L'ordre d'affichage vient de
    /// `StoredMessage.order` — passer par `orderedMessages`, jamais par
    /// `messages` directement dans l'UI.
    ///
    /// `deleteRule: .cascade` : supprimer une conversation supprime ses
    /// messages, qui suppriment à leur tour leurs sources. Cette transitivité
    /// n'est pas une supposition, elle est vérifiée par
    /// `ChatHistoryStoreTests` depuis un `ModelContext` neuf — donc en
    /// regardant réellement le store, pas le graphe d'objets déjà chargé.
    /// Sans cascade, on laisserait derrière des messages orphelins, invisibles
    /// dans l'UI mais bien présents dans le fichier SQLite : une fuite de
    /// données personnelles inacceptable pour une app qui promet un stockage
    /// 100 % local et réellement effaçable.
    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    var messages: [StoredMessage]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = []
    }

    /// Messages triés par `order` croissant : l'ordre réel de la conversation.
    /// Propriété calculée, donc jamais persistée (la macro `@Model` ne
    /// transforme que les propriétés stockées).
    var orderedMessages: [StoredMessage] {
        messages.sorted { $0.order < $1.order }
    }
}

// MARK: - Message

/// Rôle d'un message.
///
/// Stocké en `String` brut dans le modèle (voir `StoredMessage.roleRawValue`)
/// plutôt que persisté comme enum : le brut reste lisible et migrable si les
/// cas évoluent, et un rôle inconnu relu depuis un fichier écrit par une
/// version ultérieure de l'app ne fait pas échouer la lecture.
nonisolated enum StoredMessageRole: String, Sendable, Codable, CaseIterable, Equatable {
    case user
    case assistant
}

/// Un message d'une conversation sauvegardée (1.9).
///
/// Portage de la table `messages` de `src/lib/db/schema.ts`, avec un écart de
/// structure assumé et deux écarts de champs.
///
/// **Structure** : côté web, une ligne de `messages` porte UN ÉCHANGE complet —
/// la colonne `query` (la question) et la colonne `responseBlocks` (la réponse)
/// dans la même ligne, sans notion de rôle, l'ordre venant de l'`id` entier
/// auto-incrémenté. Ici une ligne = UN message, avec un `role` explicite et un
/// `order` explicite. C'est ce qu'il faut pour afficher une conversation à
/// plusieurs tours en bulles alternées, pour permettre plus tard de mettre en
/// favori une réponse seule (1.10), et pour que la question soit déjà persistée
/// pendant que la réponse est encore en cours de génération — impossible dans un
/// modèle où les deux partagent la même ligne.
///
/// **Champs** : le web stocke la réponse en tableau de `Block` JSON (son UI est
/// composée de blocs typés) ; ici le texte est une simple `String` Markdown,
/// parce que c'est exactement ce que produit
/// `AIGenerating.streamGenerate(prompt:)` et ce que la bulle de chat affiche. Et
/// la colonne `status` du web (enum `answering`/`completed`/`error`, par défaut
/// `answering`) n'est pas portée : rien n'est écrit en base avant la fin du
/// streaming (voir la politique d'écriture documentée sur `ChatHistoryStore`),
/// donc un message persisté est terminé par construction.
@Model
nonisolated final class StoredMessage {
    var id: UUID

    /// Rôle sérialisé. Côté appelant, utiliser `role`, pas cette propriété.
    var roleRawValue: String

    /// Contenu textuel : Markdown pour l'assistant, texte brut pour
    /// l'utilisateur.
    var text: String

    var createdAt: Date

    /// Position dans la conversation, croissante, strictement à la charge du
    /// store (`ChatHistoryStore.nextOrder(in:)`).
    ///
    /// Indispensable : le tableau de relation n'a pas d'ordre garanti, et
    /// trier par `createdAt` serait fragile — deux messages peuvent partager
    /// la même date à la milliseconde près quand un widget répond
    /// instantanément (1.5).
    var order: Int

    /// Conversation propriétaire, optionnelle : une relation to-one SwiftData
    /// se modélise par un optionnel, sinon il n'existe aucun état valide entre
    /// `context.insert(message)` et le rattachement à sa conversation.
    /// `deleteRule: .nullify` : supprimer un message ne doit évidemment pas
    /// supprimer la conversation qui le contient.
    ///
    /// C'est le côté SANS `inverse:` — l'inverse est déclaré une seule fois,
    /// sur `StoredConversation.messages`. Le déclarer des deux côtés ne
    /// compile pas du tout : la macro `Relationship` échoue sur
    /// « circular reference resolving attached macro 'Relationship' »
    /// (constaté, pas supposé — ce n'est donc pas un problème d'exécution mais
    /// une erreur de compilation immédiate).
    @Relationship(deleteRule: .nullify)
    var conversation: StoredConversation?

    /// Sources citées par ce message. Vide pour un message utilisateur.
    /// `.cascade` pour la même raison que plus haut : aucune source ne doit
    /// survivre au message qu'elle documente.
    @Relationship(deleteRule: .cascade, inverse: \StoredSource.message)
    var sources: [StoredSource]

    /// Décision (c) de Ben : réponse du mode Fiable restée sans source fiable
    /// (rien de généré). Persistée pour qu'une conversation relue montre le
    /// message fixe et la relance, pas une question sans réponse. Valeur par
    /// défaut : migration légère automatique des bases existantes (2026-11-01).
    var reportsNoReliableSources: Bool = false

    /// Mentions de réponse sur ses sources (mission E1a, voir `StoredAnswerNotes`). Scalaires à
    /// valeur par défaut, comme `reportsNoReliableSources` : migration légère, un message écrit
    /// avant leur ajout se relit sans mention. Lire et écrire par `answerNotes`.
    var uncitableSourceNumbersRaw: String = ""
    var answeredWithoutSearch: Bool = false
    var answeredOffline: Bool = false
    var answeredWithoutReadableSource: Bool = false

    init(
        id: UUID = UUID(),
        role: StoredMessageRole,
        text: String,
        createdAt: Date,
        order: Int
    ) {
        self.id = id
        self.roleRawValue = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.order = order
        self.sources = []
    }

    /// Rôle typé.
    ///
    /// Le repli sur `.assistant` pour une valeur brute inconnue est volontaire
    /// et documenté : relire un fichier écrit par une version ultérieure de
    /// l'app ne doit jamais faire crasher la Library. Afficher un message
    /// inconnu comme une réponse est la lecture la moins trompeuse — on
    /// n'attribuerait jamais à tort des propos à l'utilisateur.
    var role: StoredMessageRole {
        get { StoredMessageRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    /// Les mentions, en valeur.
    var answerNotes: StoredAnswerNotes {
        get {
            StoredAnswerNotes(
                uncitableSourceNumbers: SourceNumberCodec.decode(uncitableSourceNumbersRaw),
                answeredWithoutSearch: answeredWithoutSearch,
                answeredOffline: answeredOffline,
                answeredWithoutReadableSource: answeredWithoutReadableSource
            )
        }
        set {
            uncitableSourceNumbersRaw = SourceNumberCodec.encode(newValue.uncitableSourceNumbers)
            answeredWithoutSearch = newValue.answeredWithoutSearch
            answeredOffline = newValue.answeredOffline
            answeredWithoutReadableSource = newValue.answeredWithoutReadableSource
        }
    }

    /// Sources triées par `order` : l'ordre de citation `[1]`, `[2]`… tel
    /// qu'il apparaît dans le texte. `CitationParser` résout un marqueur par
    /// `sources[index - 1]`, donc `[1]` désigne l'élément d'`order` 0 :
    /// désordonner cette liste ferait pointer chaque citation sur la mauvaise
    /// source.
    var orderedSources: [StoredSource] {
        sources.sorted { $0.order < $1.order }
    }
}

// MARK: - Source

/// Une source citée par un message (titre, URL, extrait).
///
/// Instantané figé au moment de la réponse, et non une référence vivante : la
/// page peut disparaître ou changer, la citation affichée dans l'historique
/// doit rester celle qui a servi à rédiger la réponse.
@Model
nonisolated final class StoredSource {
    var id: UUID

    var title: String

    /// URL conservée en `String` et non en `URL`, pour rester exactement du
    /// même type que `SearXNGSearchResult.url` : la convertir ici créerait un
    /// point d'échec supplémentaire (une adresse qu'`URL` refuse de parser
    /// ferait perdre la source) alors que l'historique n'a besoin que de
    /// l'afficher. La conversion se fait au moment de l'ouverture du lien.
    var url: String

    /// Extrait (`content` côté SearXNG). Optionnel : certaines sources n'en
    /// renvoient aucun.
    var snippet: String?

    /// Rang de citation dans le message : `order == 0` correspond au marqueur
    /// `[1]`.
    var order: Int

    @Relationship(deleteRule: .nullify)
    var message: StoredMessage?

    init(
        id: UUID = UUID(),
        title: String,
        url: String,
        snippet: String?,
        order: Int
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.order = order
    }

    /// Convertit un résultat de recherche en source persistée.
    ///
    /// Point de passage unique entre la couche réseau (`SearXNGSearchResult`)
    /// et la couche persistance, pour que `ChatViewModel` n'ait jamais à
    /// connaître la forme du modèle SwiftData. Les champs médias
    /// (`imgSrc`, `thumbnail`…) ne sont pas conservés : l'historique affiche
    /// une liste de sources textuelles, pas la galerie de 1.6.
    convenience init(result: SearXNGSearchResult, order: Int) {
        self.init(
            title: result.title,
            url: result.url,
            snippet: result.content,
            order: order
        )
    }
}

// MARK: - Titre automatique

/// Dérive le titre d'une conversation depuis sa première question.
///
/// Le web ne dérive rien : `src/app/api/chat/route.ts` insère `title:
/// input.query`, c'est-à-dire la question brute et entière, et laisse le CSS
/// couper visuellement. Ce n'est pas portable ici pour deux raisons : une
/// cellule de liste doit annoncer un libellé borné en VoiceOver (un titre de
/// 400 caractères est inexploitable à l'oreille), et une question collée depuis
/// un PDF embarquerait ses retours à la ligne dans le titre.
///
/// On tronque donc, mais en `Character` — c'est-à-dire en grappes de
/// graphèmes — et jamais en scalaires Unicode : un drapeau 🇫🇷, une famille
/// 👨‍👩‍👧‍👦 ou un « é » décomposé (`e` + U+0301) comptent pour 1 et ne
/// peuvent jamais être coupés en deux.
nonisolated enum ConversationTitleBuilder {
    /// Titre utilisé quand la question ne contient aucun caractère visible.
    /// Un titre vide rendrait une ligne de la Library impossible à identifier
    /// et, surtout, impossible à annoncer en VoiceOver.
    static let fallbackTitle = "Nouvelle conversation"

    /// 60 grappes de graphèmes : assez pour une question complète courante,
    /// assez court pour tenir sur deux lignes d'une cellule de liste en
    /// Dynamic Type large (contrainte d'accessibilité de DESIGN.md).
    static let maxTitleLength = 60

    /// Construit le titre : espaces normalisés, coupe sur une frontière de
    /// mot, points de suspension typographiques (U+2026, **un seul
    /// caractère** — jamais trois points ASCII).
    ///
    /// Garantie utile pour la mise en page : le résultat fait AU PLUS
    /// `maxLength` caractères, points de suspension compris.
    ///
    /// `maxLength` est borné à 2 minimum : en dessous, « un caractère + … » ne
    /// tiendrait pas et le calcul de coupe n'aurait plus de sens. On borne
    /// plutôt que de lever une erreur — un titre est un confort d'affichage,
    /// pas une donnée dont une valeur limite justifierait de faire échouer la
    /// création d'une conversation.
    static func title(from question: String, maxLength: Int = maxTitleLength) -> String {
        let effectiveMax = max(2, maxLength)
        let collapsed = collapsingWhitespace(question)

        guard !collapsed.isEmpty else { return fallbackTitle }
        guard collapsed.count > effectiveMax else { return collapsed }

        return truncatingOnWordBoundary(collapsed, to: effectiveMax)
    }

    /// Remplace toute suite d'espaces ou de retours à la ligne par une espace
    /// simple. `split(whereSeparator:)` travaille sur des `Character`, donc
    /// aucun risque de découper une grappe. Une question collée depuis un PDF
    /// arrive souvent avec des retours à la ligne au milieu : sans ça, le
    /// titre de la Library contiendrait des sauts de ligne.
    private static func collapsingWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Précondition d'appel : `text.count > maxLength` et `maxLength >= 2`.
    private static func truncatingOnWordBoundary(_ text: String, to maxLength: Int) -> String {
        // Un caractère du budget est réservé aux points de suspension.
        let budget = maxLength - 1
        let head = String(text.prefix(budget))

        // `text.count > maxLength > budget`, donc cet index existe toujours.
        let nextIndex = text.index(text.startIndex, offsetBy: budget)
        let cutsInsideAWord = !text[nextIndex].isWhitespace

        var kept = head
        if cutsInsideAWord, let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            kept = String(head[head.startIndex..<lastSpace])
        }
        kept = kept.trimmingCharacters(in: .whitespaces)

        // Cas du mot unique plus long que le budget (URL, mot composé
        // allemand, chaîne d'emojis sans espace) : aucune frontière de mot
        // n'existe, on coupe net — mais toujours sur une frontière de grappe,
        // puisque `prefix` compte des `Character`.
        if kept.isEmpty {
            kept = head
        }

        return kept + "…"
    }
}
