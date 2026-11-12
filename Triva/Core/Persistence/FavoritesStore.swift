//
//  FavoritesStore.swift
//  Triva
//
//  Created by ben podrojsky on 30/09/2026.
//

import Foundation
import SwiftData

/// Erreurs des favoris.
///
/// Même construction que `ChatHistoryStoreError` : les erreurs SwiftData brutes
/// ne sont ni `Sendable` ni `Equatable`, on n'en garde que la description, et
/// aucun texte utilisateur ni aucune clé BYOK n'est interpolé ici. `throws`
/// non typé, comme dans tout le projet.
nonisolated enum FavoritesStoreError: Error, Sendable, Equatable {
    /// Une écriture (marquage, retrait, effacement) n'a pas pu être validée.
    case saveFailed(operation: String, reason: String)

    /// Une lecture a échoué.
    case fetchFailed(reason: String)

    /// Tentative de marquer un message utilisateur. Le web ne propose l'étoile
    /// que sur les réponses (`MessageActions/Favorite.tsx`), et un favori sans
    /// réponse n'aurait rien à afficher : c'est une erreur d'appel, signalée
    /// plutôt que convertie en silence en un favori incohérent.
    case notAnAssistantMessage

    /// Message court destiné à l'UI (DESIGN.md : français, factuel, sans
    /// remplissage).
    var userFacingMessage: String {
        switch self {
        case .saveFailed:
            return "Impossible de modifier les favoris."
        case .fetchFailed:
            return "Impossible de lire les favoris."
        case .notAnAssistantMessage:
            return "Seule une réponse peut être ajoutée aux favoris."
        }
    }

    /// Détail complet, réservé aux logs et aux tests.
    var diagnosticDescription: String {
        switch self {
        case .saveFailed(let operation, let reason):
            return "Échec d'écriture des favoris (\(operation)) : \(reason)"
        case .fetchFailed(let reason):
            return "Échec de lecture des favoris : \(reason)"
        case .notAnAssistantMessage:
            return "Marquage refusé : le message n'est pas une réponse de l'assistant."
        }
    }
}

/// Accès unique aux favoris (1.10).
///
/// Portage de `useFavorites.ts` (web) : `save` → `mark`, `remove` → `unmark`,
/// `isFavorited` → `isFavorite(messageID:)`, la liste `favorites` →
/// `favorites()`. Le stockage passe de `localStorage` (JSON réécrit en entier à
/// chaque changement) à SwiftData, dans le **même** `ModelContainer` que
/// l'historique (`TrivaModelContainer.shared`).
///
/// ## Conventions reprises à l'identique de `ChatHistoryStore`
/// Pour qu'un lecteur qui connaît l'un connaisse l'autre :
/// - `@Observable @MainActor`, travail sur `container.mainContext` (seul
///   contexte de l'app, que le SDK déclare `@MainActor`) ;
/// - `autosaveEnabled = false` et un `save()` explicite par opération, avec
///   `rollback()` en cas d'échec ;
/// - `revision`, incrémentée après chaque sauvegarde réussie seulement : la vue
///   Favoris s'y abonne (`.task(id: store.revision)`), et la bulle de chat qui
///   affiche l'étoile aussi ;
/// - filtrage de recherche en Swift avec `folding(options:locale:)`, locale
///   injectable pour les tests ;
/// - **une seule instance pour toute l'app** : `revision` est par instance.
///
/// ## Contexte partagé avec l'historique — conséquence à connaître
/// `FavoritesStore` et `ChatHistoryStore` utilisent le MÊME `mainContext`. Un
/// `save()` de l'un valide donc aussi toute modification en attente de l'autre,
/// et un `rollback()` de l'un l'annule. Sans conséquence aujourd'hui, puisque
/// chaque méthode des deux stores sauvegarde immédiatement et ne laisse rien en
/// attente ; ce serait à revoir si l'un d'eux se mettait à différer ses
/// écritures.
///
/// ## Recherche rapide « est-ce en favori ? »
/// La clé est l'`id` du `StoredMessage` marqué (`messageID`), stable d'un
/// lancement à l'autre. Deux accès :
/// - `isFavorite(messageID:)` : un `fetchCount` filtré par un `#Predicate`
///   d'égalité d'UUID, exécuté par SQLite sans charger aucun objet. Ici le
///   `#Predicate` est sans risque — contrairement à la recherche textuelle, il
///   n'y a ni casse ni accents à normaliser ;
/// - `favoritedMessageIDs()` : l'ensemble complet en une seule lecture, pour
///   qu'un fil de conversation de N bulles ne fasse pas N requêtes à chaque
///   rafraîchissement — l'appelant le relit quand `revision` change, puis
///   chaque bulle teste l'appartenance en O(1).
///
/// ## Après un retrait
/// Même piège que dans l'historique : un objet supprimé reste lisible sur la
/// référence retenue (`isDeleted` ne le signale pas). Après `unmark` ou
/// `deleteAll()`, relâcher les références et relire par `favorites()`.
@Observable
@MainActor
final class FavoritesStore {
    /// Conteneur retenu explicitement : il doit vivre aussi longtemps que le
    /// store, et les tests en dérivent un `ModelContext` neuf pour vérifier ce
    /// qui a réellement atteint la base.
    let container: ModelContainer

    /// Compteur d'écritures réussies, signal de rafraîchissement des vues.
    private(set) var revision = 0

    private let context: ModelContext

    /// Locale de normalisation de la recherche, injectable pour que les tests
    /// ne dépendent pas de la langue de la machine.
    private let locale: Locale

    init(container: ModelContainer, locale: Locale = .current) {
        self.container = container
        self.context = container.mainContext
        self.locale = locale
        self.context.autosaveEnabled = false
    }

    // MARK: - Marquage

    /// Met en favori une réponse de l'historique.
    ///
    /// La question est retrouvée dans la conversation : c'est le dernier
    /// message utilisateur qui PRÉCÈDE la réponse (par `order`), et non le
    /// premier de la conversation — dans un échange à plusieurs tours, la
    /// réponse n° 3 répond à la question n° 3. Les sources sont recopiées dans
    /// l'ordre de citation (`orderedSources`).
    ///
    /// Idempotent : si ce message est déjà en favori, le favori existant est
    /// renvoyé tel quel (voir `mark(messageID:…)`).
    @discardableResult
    func mark(_ message: StoredMessage, now: Date = .now) throws -> StoredFavorite {
        guard message.role == .assistant else {
            throw FavoritesStoreError.notAnAssistantMessage
        }
        if let existing = try favorite(forMessageID: message.id) {
            return existing
        }

        let favorite = StoredFavorite(
            messageID: message.id,
            conversationID: message.conversation?.id,
            question: Self.question(answeredBy: message),
            answer: message.text,
            savedAt: now
        )
        favorite.uncitableSourceNumbers = message.answerNotes.uncitableSourceNumbers
        let copies = message.orderedSources.enumerated().map { index, source in
            StoredFavoriteSource(copying: source, order: index)
        }
        return try insert(favorite, sources: copies)
    }

    /// Met en favori une réponse décrite champ par champ.
    ///
    /// Point d'entrée pour le chat, qui détient les sources sous forme de
    /// `SearXNGSearchResult` : passer **exactement** le tableau que
    /// `CitationParser` résout, `sources[0]` devient la source d'`order` 0 que
    /// désigne `[1]`.
    ///
    /// `messageID` doit être l'`id` du `StoredMessage` correspondant (celui que
    /// renvoie `ChatHistoryStore.appendAssistantMessage`), et non l'identifiant
    /// éphémère d'une bulle : sinon, après relancement, la Library ne
    /// reconnaîtrait pas ce favori.
    ///
    /// **Pas de doublon** : si un favori existe déjà pour ce `messageID`, il est
    /// renvoyé inchangé, sans écriture ni changement de `revision`. Écart
    /// volontaire avec le web, qui remplace l'entrée et la remonte en tête :
    /// taper deux fois sur une étoile déjà pleine ne doit ni réécrire la date ni
    /// réordonner la liste. Retirer puis remarquer, en revanche, crée un favori
    /// neuf daté du nouveau marquage.
    @discardableResult
    func mark(
        messageID: UUID,
        conversationID: UUID?,
        question: String,
        answer: String,
        sources: [SearXNGSearchResult] = [],
        uncitableSourceNumbers: Set<Int> = [],
        now: Date = .now
    ) throws -> StoredFavorite {
        if let existing = try favorite(forMessageID: messageID) {
            return existing
        }

        let favorite = StoredFavorite(
            messageID: messageID,
            conversationID: conversationID,
            question: question,
            answer: answer,
            savedAt: now
        )
        favorite.uncitableSourceNumbers = uncitableSourceNumbers
        let copies = sources.enumerated().map { index, result in
            StoredFavoriteSource(result: result, order: index)
        }
        return try insert(favorite, sources: copies)
    }

    /// Bascule l'étoile d'une réponse de l'historique. Renvoie le NOUVEL état
    /// (`true` = désormais en favori), ce qu'il faut à la bulle pour annoncer le
    /// changement en VoiceOver.
    @discardableResult
    func toggle(_ message: StoredMessage, now: Date = .now) throws -> Bool {
        if try isFavorite(messageID: message.id) {
            try unmark(messageID: message.id)
            return false
        }
        try mark(message, now: now)
        return true
    }

    private func insert(
        _ favorite: StoredFavorite,
        sources: [StoredFavoriteSource]
    ) throws -> StoredFavorite {
        context.insert(favorite)
        for source in sources {
            context.insert(source)
            source.favorite = favorite
        }
        try save(operation: "ajout d'un favori")
        return favorite
    }

    /// Question à laquelle `message` répond : le dernier message utilisateur
    /// d'`order` inférieur. Chaîne vide si le message n'a pas de conversation
    /// ou si aucune question ne le précède (cas qui ne devrait pas exister dans
    /// l'app, mais qu'un store relu ne doit pas transformer en erreur — l'UI
    /// affiche alors un libellé de repli).
    private static func question(answeredBy message: StoredMessage) -> String {
        guard let conversation = message.conversation else { return "" }
        let precedingQuestion = conversation.orderedMessages.last(where: { candidate in
            candidate.role == .user && candidate.order < message.order
        })
        return precedingQuestion?.text ?? ""
    }

    // MARK: - Retrait

    /// Retire des favoris la réponse `messageID`. Renvoie `true` si quelque
    /// chose a été retiré, `false` si ce message n'était pas en favori — auquel
    /// cas rien n'est écrit et `revision` ne bouge pas.
    ///
    /// Retire TOUS les favoris portant ce `messageID` : `mark` n'en crée jamais
    /// deux, mais un fichier écrit par une autre version de l'app pourrait en
    /// contenir. Une étoile qui resterait pleine après un retrait serait un bug
    /// incompréhensible pour l'utilisateur.
    @discardableResult
    func unmark(messageID: UUID) throws -> Bool {
        let matches = try favorites(forMessageID: messageID)
        guard !matches.isEmpty else { return false }

        for favorite in matches {
            context.delete(favorite)
        }
        try save(operation: "retrait d'un favori")
        return true
    }

    /// Retire un favori déjà chargé (bouton de suppression de la liste).
    func remove(_ favorite: StoredFavorite) throws {
        context.delete(favorite)
        try save(operation: "retrait d'un favori")
    }

    /// Vide les favoris. Objet par objet dans une seule transaction, pour
    /// n'avoir qu'un chemin de suppression — celui dont la cascade vers les
    /// sources est couverte par les tests (même choix que
    /// `ChatHistoryStore.deleteAll()`). N'affecte en rien l'historique.
    func deleteAll() throws {
        for favorite in try favorites() {
            context.delete(favorite)
        }
        try save(operation: "effacement des favoris")
    }

    // MARK: - Recherche rapide

    /// `true` si la réponse `messageID` est en favori. Compte SQLite, aucun
    /// objet chargé.
    func isFavorite(messageID: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<StoredFavorite>(predicate: Self.matching(messageID))
        do {
            return try context.fetchCount(descriptor) > 0
        } catch {
            throw FavoritesStoreError.fetchFailed(reason: String(describing: error))
        }
    }

    /// Identifiants de tous les messages en favori, en une seule lecture —
    /// voir « Recherche rapide » en tête de type.
    func favoritedMessageIDs() throws -> Set<UUID> {
        Set(try favorites().map(\.messageID))
    }

    /// Favori associé à `messageID`, s'il existe.
    func favorite(forMessageID messageID: UUID) throws -> StoredFavorite? {
        try favorites(forMessageID: messageID).first
    }

    private func favorites(forMessageID messageID: UUID) throws -> [StoredFavorite] {
        let descriptor = FetchDescriptor<StoredFavorite>(predicate: Self.matching(messageID))
        do {
            return try context.fetch(descriptor)
        } catch {
            throw FavoritesStoreError.fetchFailed(reason: String(describing: error))
        }
    }

    /// L'UUID est capturé dans une constante locale avant d'entrer dans la
    /// macro : un `#Predicate` ne sait traduire en SQL que des valeurs
    /// capturées, pas un accès à une propriété d'un objet extérieur.
    private static func matching(_ messageID: UUID) -> Predicate<StoredFavorite> {
        let target = messageID
        return #Predicate<StoredFavorite> { $0.messageID == target }
    }

    // MARK: - Liste

    /// Favoris du plus récemment marqué au plus ancien (ordre du web, qui
    /// insère en tête : `[entry, ...filtered]`).
    ///
    /// Départage sur `question` puis `answer` : sans critère secondaire, deux
    /// favoris marqués à la même date auraient un ordre indéterminé et la liste
    /// « sauterait » d'un affichage à l'autre.
    ///
    /// Un `limit` nul ou négatif renvoie une liste vide et n'est jamais transmis
    /// à `fetchLimit` (même raisonnement que `ChatHistoryStore.conversations`).
    func favorites(limit: Int? = nil) throws -> [StoredFavorite] {
        if let limit, limit <= 0 { return [] }

        var descriptor = FetchDescriptor<StoredFavorite>(
            sortBy: [
                SortDescriptor(\StoredFavorite.savedAt, order: .reverse),
                SortDescriptor(\StoredFavorite.question),
                SortDescriptor(\StoredFavorite.answer),
            ]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }

        do {
            return try context.fetch(descriptor)
        } catch {
            throw FavoritesStoreError.fetchFailed(reason: String(describing: error))
        }
    }

    /// Recherche dans la question, la réponse et le titre des sources,
    /// insensible à la casse et aux accents.
    ///
    /// Filtrage en Swift pour la même raison que l'historique : la
    /// normalisation diacritique d'un `#Predicate` dépend de sa traduction SQL,
    /// alors que `folding(options:locale:)` est déterministe et testable. Les
    /// volumes (quelques centaines de favoris au plus) rendent le coût
    /// négligeable.
    ///
    /// Requête vide → tous les favoris. `limit` s'applique APRÈS le filtre.
    func favorites(matching query: String, limit: Int? = nil) throws -> [StoredFavorite] {
        let needle = normalized(query)
        let all = try favorites()

        let matches = needle.isEmpty ? all : all.filter { contains(needle, in: $0) }
        guard let limit else { return matches }
        return Array(matches.prefix(max(0, limit)))
    }

    private func contains(_ needle: String, in favorite: StoredFavorite) -> Bool {
        if normalized(favorite.question).contains(needle) { return true }
        if normalized(favorite.answer).contains(needle) { return true }
        return favorite.sources.contains { normalized($0.title).contains(needle) }
    }

    /// Normalisation identique à celle de `ChatHistoryStore` (qui la garde
    /// privée) : casse, accents et largeur ignorés, espaces de bord retirés.
    private func normalized(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sauvegarde

    private func save(operation: String) throws {
        do {
            try context.save()
        } catch {
            // Sans `rollback()`, la modification refusée resterait en attente et
            // ferait échouer toutes les sauvegardes suivantes — y compris celles
            // de `ChatHistoryStore`, qui partage ce contexte.
            context.rollback()
            throw FavoritesStoreError.saveFailed(
                operation: operation,
                reason: String(describing: error)
            )
        }
        revision += 1
    }
}
