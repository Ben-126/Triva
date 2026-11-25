//
//  ConversationEntity.swift
//  Triva
//
//  Chantier 2.1 (mission A) : une conversation de l'historique, vue par Raccourcis, Siri et (mission F) Spotlight.
//  Le titre et la date seulement : jamais le texte des réponses.
//

import AppIntents
import Foundation

nonisolated struct ConversationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Conversation")
    }

    static var defaultQuery: ConversationQuery { ConversationQuery() }

    let id: UUID

    private let storedTitle: String
    private let storedUpdatedAt: Date

    @ComputedProperty(title: "Titre")
    var title: String { storedTitle }

    @ComputedProperty(title: "Dernière modification")
    var updatedAt: Date { storedUpdatedAt }

    init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.storedTitle = title
        self.storedUpdatedAt = updatedAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: LocalizedStringResource(stringLiteral: updatedAt.formatted(date: .abbreviated, time: .omitted))
        )
    }
}

/// Ce que l'historique ne peut pas lire : message clair pour Raccourcis et Siri.
nonisolated enum ConversationQueryError: Error, CustomLocalizedStringResourceConvertible {
    case historyUnavailable

    var localizedStringResource: LocalizedStringResource {
        "L'historique de Triva n'est pas lisible pour le moment."
    }
}

/// Trouve les conversations pour Raccourcis, Siri et Spotlight. La logique est dans des fonctions statiques qui
/// prennent le store : le registre de dépendances de l'app ne se contrôle pas depuis un test.
struct ConversationQuery: EntityStringQuery {
    /// Résultats d'une recherche au plus.
    static let searchLimit = 20
    /// Suggestions au plus.
    static let suggestionLimit = 10

    @Dependency var services: TrivaAppServices

    init() {}

    // MARK: Protocole

    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        let services = services
        return try await MainActor.run {
            try Self.entities(for: identifiers, in: services.stores.chatHistory)
        }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        let services = services
        return try await MainActor.run {
            try Self.entities(matching: string, in: services.stores.chatHistory)
        }
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        let services = services
        return try await MainActor.run {
            try Self.suggested(in: services.stores.chatHistory)
        }
    }

    // MARK: Logique (testée)

    /// Les conversations connues parmi ces identifiants, dans l'ordre demandé ; les inconnues sont absentes.
    @MainActor
    static func entities(for ids: [UUID], in store: ChatHistoryStore) throws -> [ConversationEntity] {
        // Une lecture par identifiant demandé : jamais tout l'historique chargé pour quelques raccourcis.
        return try ids.compactMap { id in
            try read { try store.conversation(with: id).map { [$0] } ?? [] }.first.map(entity(from:))
        }
    }

    /// Recherche dans les titres ET le texte des conversations (casse et accents ignorés), les plus récentes
    /// d'abord, `searchLimit` au plus. Seuls le titre et la date sortent d'ici.
    @MainActor
    static func entities(matching text: String, in store: ChatHistoryStore) throws -> [ConversationEntity] {
        try read { try store.conversations(matching: text, limit: searchLimit) }.map(entity(from:))
    }

    /// Les `suggestionLimit` conversations les plus récentes.
    @MainActor
    static func suggested(in store: ChatHistoryStore) throws -> [ConversationEntity] {
        try read { try store.conversations(limit: suggestionLimit) }.map(entity(from:))
    }

    // MARK: Privé

    @MainActor
    private static func entity(from conversation: StoredConversation) -> ConversationEntity {
        ConversationEntity(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt)
    }

    @MainActor
    private static func read(_ body: () throws -> [StoredConversation]) throws -> [StoredConversation] {
        do {
            return try body()
        } catch {
            throw ConversationQueryError.historyUnavailable
        }
    }
}
