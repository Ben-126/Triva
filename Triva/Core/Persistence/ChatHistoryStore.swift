//
//  ChatHistoryStore.swift
//  Triva
//
//  Created by ben podrojsky on 24/09/2026.
//

import Foundation
import SwiftData

/// Erreurs de l'historique.
///
/// Les erreurs SwiftData brutes ne sont ni `Sendable` ni `Equatable` : on
/// conserve leur description pour le diagnostic, jamais l'instance. Aucun
/// texte utilisateur ni aucune clé BYOK n'est interpolé ici (cette couche n'en
/// voit aucune) — même principe de prudence que
/// `ChatViewModel.userFacingMessage(for:)`.
///
/// `throws` non typé, comme partout ailleurs dans le projet : l'enum dédié et
/// `Equatable` suffit aux tests, et `throws(ChatHistoryStoreError)` ici serait
/// la seule occurrence de typed throws de la base.
nonisolated enum ChatHistoryStoreError: Error, Sendable, Equatable {
    /// Une écriture (insertion, modification, suppression) n'a pas pu être
    /// validée. L'opération est nommée en français pour rendre le log
    /// directement lisible.
    case saveFailed(operation: String, reason: String)

    /// Une lecture a échoué.
    case fetchFailed(reason: String)

    /// La base locale n'a pas pu être ouverte (`TrivaStorage`) : aucune lecture
    /// ni écriture n'est tentée, plutôt que d'écrire dans un stockage qui
    /// disparaîtrait à la fermeture.
    case storageUnavailable

    /// Message court destiné à l'UI : français, factuel, sans détail
    /// technique et sans remplissage (DESIGN.md).
    var userFacingMessage: String {
        switch self {
        case .saveFailed:
            return "Impossible d'enregistrer dans l'historique."
        case .fetchFailed:
            return "Impossible de lire l'historique."
        case .storageUnavailable:
            // À VALIDER PAR BEN. Affiché dans le chat quand un échange n'a pas pu être enregistré.
            return "Tes conversations enregistrées sont inaccessibles : cet échange ne sera pas enregistré."
        }
    }

    /// Détail complet, réservé aux logs et aux tests.
    var diagnosticDescription: String {
        switch self {
        case .saveFailed(let operation, let reason):
            return "Échec d'écriture (\(operation)) : \(reason)"
        case .fetchFailed(let reason):
            return "Échec de lecture : \(reason)"
        case .storageUnavailable:
            return "Base locale indisponible : lecture et écriture refusées."
        }
    }
}

/// Accès unique à l'historique de conversations (1.9).
///
/// ## Rôle
/// C'est la SEULE porte d'entrée vers SwiftData : ni les vues ni
/// `ChatViewModel` n'importent `SwiftData` ou ne manipulent un `ModelContext`.
/// Contrainte du plan, et bonne raison pratique : la politique d'écriture
/// pendant le streaming (ci-dessous) ne tient que si un seul endroit décide
/// quand on écrit.
///
/// ## Isolation
/// `@MainActor` explicite, et non laissé au hasard de
/// `-default-isolation=MainActor` : le store travaille sur le `mainContext` du
/// conteneur, que le SDK déclare lui-même `@MainActor`, et les modèles
/// (`StoredConversation` & co.) ne sont **pas `Sendable`** — leur conformance
/// est déclarée `unavailable` par la macro `@Model`, donc les faire traverser
/// une frontière d'isolation est refusé par le compilateur. Un `@ModelActor`
/// d'arrière-plan a été écarté ; justification complète en tête de
/// `ChatHistoryModels.swift`.
///
/// Un seul `ModelContext` (`mainContext`) pour toute l'app, jamais un contexte
/// dédié : deux contextes sur le même conteneur divergent tant qu'aucun des
/// deux ne refetche, et une conversation créée dans l'un resterait invisible
/// dans l'autre.
///
/// ## Politique d'écriture pendant le streaming (POINT CRITIQUE)
/// `ChatViewModel.send(query:)` reçoit du provider IA des **snapshots
/// cumulatifs** : chaque `yield` de `AIGenerating.streamGenerate(prompt:)`
/// porte le texte complet, que la vue réaffecte en entier
/// (`message.text = snapshot`), plusieurs dizaines de fois par seconde.
/// Enregistrer chaque snapshot signifierait autant de transactions SQLite **sur
/// le main actor** : saccades garanties pendant que le texte défile, pour une
/// valeur nulle.
///
/// Règle retenue, à appliquer telle quelle par `ChatViewModel` :
/// 1. **Le message utilisateur est persisté à l'envoi**
///    (`appendUserMessage`), avant même de lancer la recherche. Écriture
///    unique et bon marché, et c'est elle qui garantit qu'une conversation
///    interrompue ne disparaît pas.
/// 2. **Le message assistant est persisté AU PLUS UNE FOIS, à la fin du
///    streaming, QUELLE QU'EN SOIT LA CAUSE** : succès, erreur, ou annulation
///    (écran quitté, moteur changé — voir `stopStreamingWithoutError`), avec le
///    texte partiel disponible à cet instant. Un appel unique à
///    `appendAssistantMessage(to:text:sources:)`. Ne jamais câbler ce point
///    uniquement sur le chemin nominal : une génération annulée laisserait
///    alors une question sans réponse dans l'historique.
/// 3. **Exception, texte vide** : si le texte partiel est vide ou ne contient
///    que des espaces, ne PAS appeler `appendAssistantMessage`. La question
///    seule reste dans l'historique. C'est le cas que `ChatViewModel` traite
///    déjà en `ChatViewModelError.emptyResponse` ; une bulle de réponse vide
///    relue dans la Library serait indistinguable d'un bug, alors qu'une
///    question sans réponse se lit correctement. Le store, lui, n'arbitre
///    pas : il écrit fidèlement ce qu'on lui donne (comportement figé par un
///    test), parce qu'un store qui jette silencieusement des données est pire
///    qu'une règle d'appel écrite noir sur blanc.
/// 4. Aucune écriture entre les deux. `updateText(of:to:)` existe pour les
///    modifications ponctuelles ultérieures (régénérer une réponse, corriger),
///    jamais pour le streaming.
///
/// Ce qu'on accepte de perdre : si l'app est tuée *pendant* une génération, la
/// réponse partielle est perdue — la question, elle, est déjà en base.
/// Arbitrage assumé : une réponse tronquée à mi-phrase a peu de valeur, une UI
/// qui saccade en a une négative.
///
/// ## Signal de changement pour les vues
/// `@Observable` + `revision` : l'historique n'est pas lu par `@Query` (le plan
/// interdit SwiftData dans les vues), donc rien ne rafraîchirait la Library
/// toute seule. Sur iPad en `regular` et sur macOS, la Library et la Recherche
/// sont à l'écran **en même temps** : une liste récupérée une fois deviendrait
/// périmée dès que le Chat ajoute un message. `revision` est incrémentée après
/// CHAQUE sauvegarde réussie, et seulement en cas de succès — une vue
/// s'abonne avec `.task(id: store.revision) { … }` ou lit la valeur dans son
/// `body` pour se voir invalider.
///
/// ## Piège : ne plus jamais toucher une référence après `delete(_:)`
/// `isDeleted` ne signale PAS la suppression : mesuré après `delete(_:)` +
/// `save()`, il vaut encore `false` sur la référence retenue, dont le `title` et
/// les `messages` répondaient toujours — alors que le store ne contient plus
/// rien. Une vue qui garde l'objet afficherait donc une conversation fantôme, et
/// sur un store sur disque toucher un objet supprimé peut être bien plus
/// brutal qu'une simple valeur périmée.
///
/// **Règle, sans exception : après `delete(_:)` ou `deleteAll()`, relâcher la
/// référence et relire par `conversations()`.** Ne jamais tester `isDeleted`
/// pour décider si un objet est encore valide.
///
/// ## Autosave
/// `autosaveEnabled` est mis à `false` : chaque méthode sauvegarde
/// explicitement. Sans ça, SwiftData validerait à des moments choisis par le
/// runtime, ce qui rendrait la politique ci-dessus illusoire et les tests non
/// déterministes.
@Observable
@MainActor
final class ChatHistoryStore {
    /// Stockage partagé avec `FavoritesStore` (voir `TrivaStorage`) : un
    /// « Réessayer » réussi rebranche les deux stores d'un coup.
    let storage: TrivaStorage

    /// Conteneur du stockage : les tests en dérivent un `ModelContext` neuf
    /// pour vérifier ce qui a réellement atteint la base. Quand le stockage est
    /// indisponible, c'est un conteneur de réserve vide, jamais lu ni écrit.
    var container: ModelContainer { storage.container }

    /// Compteur d'écritures réussies, plus les ouvertures réussies du stockage
    /// après un échec. Voir « Signal de changement » ci-dessus. Calculé :
    /// personne d'autre que le store et le stockage ne décide qu'un changement
    /// a eu lieu.
    var revision: Int { writeCount + storage.generation }

    private var writeCount = 0

    /// Locale utilisée pour normaliser la recherche (casse et accents).
    /// Injectable pour que les tests ne dépendent pas de la langue de la
    /// machine — le repliement de casse a des cas particuliers propres à
    /// certaines langues (le `i` turc, notamment).
    private let locale: Locale

    convenience init(container: ModelContainer, locale: Locale = .current) {
        self.init(storage: TrivaStorage(container: container), locale: locale)
    }

    init(storage: TrivaStorage, locale: Locale = .current) {
        self.storage = storage
        self.locale = locale
    }

    /// Contexte unique de l'app, ou `storageUnavailable` : toute lecture et
    /// toute écriture passent par ici, aucune ne peut donc viser le conteneur
    /// de réserve.
    private func readyContext() throws -> ModelContext {
        guard let context = storage.context else { throw ChatHistoryStoreError.storageUnavailable }
        return context
    }

    /// Retente l'ouverture de la base (bouton « Réessayer » de l'écran
    /// d'erreur). `true` si elle est disponible à l'issue.
    @discardableResult
    func retryOpeningStorage() -> Bool { storage.retry() }

    // MARK: - Création

    /// Crée une conversation dont le titre est dérivé de la première question.
    ///
    /// Le message n'est PAS ajouté ici : l'appelant enchaîne avec
    /// `appendUserMessage`. Deux responsabilités distinctes — et le titre doit
    /// pouvoir être calculé même pour une conversation ouverte à blanc.
    @discardableResult
    func createConversation(firstQuestion: String, now: Date = .now) throws -> StoredConversation {
        try createConversation(title: ConversationTitleBuilder.title(from: firstQuestion), now: now)
    }

    /// Crée une conversation au titre imposé.
    ///
    /// `now` est un paramètre plutôt qu'un `Date.now` lu en interne : les
    /// tests doivent pouvoir fabriquer un ordre chronologique exact sans
    /// dormir, et l'app pourra réimporter une conversation en conservant ses
    /// dates d'origine.
    @discardableResult
    func createConversation(title: String, now: Date = .now) throws -> StoredConversation {
        let conversation = StoredConversation(title: title, createdAt: now, updatedAt: now)
        try readyContext().insert(conversation)
        try save(operation: "création d'une conversation")
        return conversation
    }

    // MARK: - Messages

    /// Ajoute la question de l'utilisateur. À appeler au moment de l'envoi
    /// (voir la politique d'écriture en tête de type).
    @discardableResult
    func appendUserMessage(
        to conversation: StoredConversation,
        text: String,
        now: Date = .now
    ) throws -> StoredMessage {
        try append(role: .user, text: text, sources: [], to: conversation, now: now)
    }

    /// Ajoute la réponse de l'assistant. À appeler **au plus une fois, à la fin
    /// du streaming**, que celui-ci se soit terminé normalement, en erreur ou
    /// par annulation — et jamais avec un texte vide (point 3 de la politique).
    /// `notes` : les mentions sur les sources (`StoredAnswerNotes`), écrites avec le message
    /// pour qu'une conversation relue les redise.
    @discardableResult
    func appendAssistantMessage(
        to conversation: StoredConversation,
        text: String,
        sources: [SearXNGSearchResult] = [],
        notes: StoredAnswerNotes = StoredAnswerNotes(),
        now: Date = .now
    ) throws -> StoredMessage {
        let message = try append(role: .assistant, text: text, sources: sources, to: conversation, now: now, save: false)
        message.answerNotes = notes
        try save(operation: "ajout d'un message")
        return message
    }

    /// Décision (c) : réponse « Aucune source fiable » (mode Fiable), écrite à
    /// la fin de l'échange à la place d'une réponse. Texte = message fixe, pour
    /// les aperçus de la Library ; c'est `reportsNoReliableSources` qui fait foi.
    @discardableResult
    func appendNoReliableSourcesMessage(
        to conversation: StoredConversation,
        text: String,
        now: Date = .now
    ) throws -> StoredMessage {
        let message = try append(role: .assistant, text: text, sources: [], to: conversation, now: now, save: false)
        message.reportsNoReliableSources = true
        try save(operation: "ajout d'un message")
        return message
    }

    /// Supprime UN message (relance en mode Rapide d'une réponse « Aucune
    /// source fiable » : la nouvelle réponse la remplace). Ses sources partent
    /// avec lui (cascade). `nextOrder` utilise `max(order) + 1` : un trou dans
    /// les positions est sans effet.
    func delete(_ message: StoredMessage) throws {
        let context = try readyContext()
        message.conversation?.updatedAt = .now
        context.delete(message)
        try save(operation: "suppression d'un message")
    }

    private func append(
        role: StoredMessageRole,
        text: String,
        sources: [SearXNGSearchResult],
        to conversation: StoredConversation,
        now: Date,
        save shouldSave: Bool = true
    ) throws -> StoredMessage {
        let context = try readyContext()
        let message = StoredMessage(
            role: role,
            text: text,
            createdAt: now,
            order: nextOrder(in: conversation)
        )
        context.insert(message)
        message.conversation = conversation

        // L'ordre du tableau de sources EST l'ordre de citation : `sources[0]`
        // devient la source d'`order` 0, que `CitationParser` résout depuis le
        // marqueur `[1]`.
        for (index, result) in sources.enumerated() {
            let source = StoredSource(result: result, order: index)
            context.insert(source)
            source.message = message
        }

        conversation.updatedAt = now
        if shouldSave {
            try save(operation: "ajout d'un message")
        }
        return message
    }

    /// Prochaine position libre : `max(order) + 1`, et non `messages.count`.
    ///
    /// La différence compte dès qu'un message est supprimé individuellement
    /// (ce que les Favoris ou une édition pourront introduire) : avec `count`,
    /// on réattribuerait une position déjà utilisée et l'ordre d'affichage
    /// deviendrait faux en silence.
    ///
    /// Lire `conversation.messages` juste après un `message.conversation = …`
    /// est fiable : l'inverse de la relation est peuplé immédiatement, sans
    /// attendre le `save()` (vérifié à l'exécution).
    private func nextOrder(in conversation: StoredConversation) -> Int {
        (conversation.messages.map(\.order).max() ?? -1) + 1
    }

    /// Remplace le texte d'un message déjà persisté (régénération, correction).
    ///
    /// Met à jour `updatedAt` de la conversation : une correction est une
    /// activité, la conversation doit remonter dans la Library.
    func updateText(of message: StoredMessage, to text: String, now: Date = .now) throws {
        message.text = text
        message.conversation?.updatedAt = now
        try save(operation: "mise à jour d'un message")
    }

    /// Renomme une conversation.
    ///
    /// Un titre vide ou uniquement composé d'espaces est remplacé par le titre
    /// de repli plutôt que refusé : une ligne de Library sans libellé serait
    /// impossible à identifier et, surtout, impossible à annoncer en VoiceOver.
    func rename(_ conversation: StoredConversation, to title: String, now: Date = .now) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.title = trimmed.isEmpty ? ConversationTitleBuilder.fallbackTitle : trimmed
        conversation.updatedAt = now
        try save(operation: "renommage d'une conversation")
    }

    // MARK: - Lecture

    /// Conversations les plus récemment actives d'abord.
    ///
    /// Tri sur `updatedAt` (activité) puis `createdAt` en départage : sans ce
    /// second critère, deux conversations partageant le même `updatedAt` (cas
    /// courant dans un test, possible dans l'app) auraient un ordre
    /// indéterminé et la liste « sauterait » d'un affichage à l'autre.
    ///
    /// Un `limit` nul ou négatif renvoie une liste vide, et n'est surtout PAS
    /// transmis à `fetchLimit` : celui-ci est un `Int?` où seul `nil` signifie
    /// « aucune limite », et rien ne garantit qu'un `0` soit interprété comme
    /// « zéro résultat » par le store sous-jacent. Demander zéro conversation
    /// et les recevoir toutes serait le pire des comportements possibles.
    func conversations(limit: Int? = nil) throws -> [StoredConversation] {
        if let limit, limit <= 0 { return [] }

        var descriptor = FetchDescriptor<StoredConversation>(
            sortBy: [
                SortDescriptor(\StoredConversation.updatedAt, order: .reverse),
                SortDescriptor(\StoredConversation.createdAt, order: .reverse),
            ]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }

        let context = try readyContext()
        do {
            return try context.fetch(descriptor)
        } catch {
            throw ChatHistoryStoreError.fetchFailed(reason: String(describing: error))
        }
    }

    /// Retrouve une conversation par son `id` métier (celui du modèle, pas le
    /// `persistentModelID` interne) : c'est ce que manipule la Library pour
    /// rouvrir une conversation, et ce que les Favoris (1.10) référenceront.
    ///
    /// Filtrage en Swift plutôt qu'avec un `#Predicate`, pour la même raison
    /// que la recherche ci-dessous : sur des volumes locaux, la simplicité et
    /// le déterminisme valent mieux qu'une traduction SQL opaque.
    func conversation(with id: UUID) throws -> StoredConversation? {
        try conversations().first { $0.id == id }
    }

    /// Recherche dans les titres ET le contenu des messages, insensible à la
    /// casse et aux accents.
    ///
    /// Le filtrage se fait en Swift, pas dans un `#Predicate` : la
    /// normalisation diacritique d'un `#Predicate` est traduite en SQL par le
    /// store et son comportement en dépend, alors que
    /// `folding(options:locale:)` est déterministe et directement testable —
    /// or « accents ignorés » est une exigence explicite du plan. Le coût est
    /// acceptable : l'historique est local et se compte en centaines de
    /// conversations, pas en millions.
    ///
    /// Une requête vide renvoie toute la liste : vider le champ de recherche
    /// doit réafficher l'historique, pas un écran vide.
    ///
    /// `limit` s'applique **après** le filtrage. Le poser sur le fetch
    /// renverrait moins de résultats qu'il n'en existe, puisque le tri
    /// précède le filtre.
    func conversations(matching query: String, limit: Int? = nil) throws -> [StoredConversation] {
        let needle = normalized(query)
        let all = try conversations()

        guard !needle.isEmpty else {
            return limited(all, to: limit)
        }

        let matches = all.filter { conversation in
            if normalized(conversation.title).contains(needle) { return true }
            return conversation.messages.contains { normalized($0.text).contains(needle) }
        }
        return limited(matches, to: limit)
    }

    private func limited(
        _ conversations: [StoredConversation],
        to limit: Int?
    ) -> [StoredConversation] {
        guard let limit else { return conversations }
        return Array(conversations.prefix(max(0, limit)))
    }

    /// Normalisation commune à la requête et au texte comparé : casse,
    /// accents et largeur des caractères ignorés, espaces de bord retirés.
    private func normalized(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Suppression

    /// Supprime une conversation. Ses messages et les sources de ces messages
    /// partent avec elle (cascade déclarée dans `ChatHistoryModels.swift`,
    /// vérifiée par test depuis un contexte neuf — c'est la promesse
    /// « historique réellement effaçable »).
    ///
    /// Attention au piège documenté en tête de type : la référence passée ici
    /// reste lisible après coup, il faut la relâcher.
    func delete(_ conversation: StoredConversation) throws {
        try readyContext().delete(conversation)
        try save(operation: "suppression d'une conversation")
    }

    /// Efface tout l'historique.
    ///
    /// Suppression objet par objet dans une seule transaction. Ce n'est pas
    /// parce que `context.delete(model:where:)` serait cassé : vérification
    /// faite à l'exécution, la suppression en masse applique bien les règles de
    /// cascade et ne laisse ni message ni source derrière elle. C'est pour
    /// n'avoir qu'UN seul chemin de suppression dans le store — celui que le
    /// test de cascade couvre déjà — au lieu de deux dont un seul est
    /// réellement exercé. Les volumes (centaines de conversations) rendent la
    /// différence de coût sans objet.
    func deleteAll() throws {
        let context = try readyContext()
        for conversation in try conversations() {
            context.delete(conversation)
        }
        try save(operation: "effacement de l'historique")
    }

    // MARK: - Sauvegarde

    private func save(operation: String) throws {
        let context = try readyContext()
        do {
            try context.save()
        } catch {
            // `rollback()` remet le contexte dans un état cohérent : sans ça,
            // la modification refusée resterait en attente et ferait échouer
            // toutes les sauvegardes suivantes, y compris celles qui n'ont
            // rien à voir avec elle.
            context.rollback()
            throw ChatHistoryStoreError.saveFailed(
                operation: operation,
                reason: String(describing: error)
            )
        }

        // Après le `save()` seulement : une écriture refusée puis annulée n'est
        // pas un changement, et réveiller les vues pour rien leur ferait
        // afficher un état qui n'existe pas.
        writeCount += 1
    }
}
