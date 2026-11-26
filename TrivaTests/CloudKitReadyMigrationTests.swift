//
//  CloudKitReadyMigrationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Triva

// Chantier 2.3, mission K1 : rendre le modèle compatible CloudKit (relations to-many optionnelles,
// valeurs par défaut) ne doit JAMAIS faire perdre l'historique existant de l'utilisateur.
// On écrit un VRAI fichier SQLite avec le modèle d'AVANT K1 (copie fidèle des cinq classes, mêmes
// noms d'entités, relations to-many NON optionnelles, attributs sans valeur par défaut), puis on le
// rouvre par le chemin de l'app (`Schema(TrivaModelContainer.models)`, sans plan de migration :
// migration légère automatique, comme `StoredAnswerNotesMigrationTests`). Fichier dans un dossier
// temporaire, JAMAIS le store de l'utilisateur.

/// Le modèle d'avant la mission K1 (état du dépôt au commit b0c2c6d). Classes enveloppées dans un
/// `enum` pour ne pas entrer en collision avec les modèles actuels ; le NOM de la classe désigne
/// l'entité en base.
private enum PreCloudKitSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [StoredConversation.self, StoredMessage.self, StoredSource.self, StoredFavorite.self, StoredFavoriteSource.self]
    }

    @Model
    final class StoredConversation {
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.messages = []
        }
    }

    @Model
    final class StoredMessage {
        var id: UUID
        var roleRawValue: String
        var text: String
        var createdAt: Date
        var order: Int
        @Relationship(deleteRule: .nullify)
        var conversation: StoredConversation?
        @Relationship(deleteRule: .cascade, inverse: \StoredSource.message)
        var sources: [StoredSource]
        var reportsNoReliableSources: Bool = false
        var uncitableSourceNumbersRaw: String = ""
        var answeredWithoutSearch: Bool = false
        var answeredOffline: Bool = false
        var answeredWithoutReadableSource: Bool = false
        var sourcesMayBeOffTopic: Bool = false
        var searXNGUnreachable: Bool = false

        init(id: UUID, roleRawValue: String, text: String, createdAt: Date, order: Int) {
            self.id = id
            self.roleRawValue = roleRawValue
            self.text = text
            self.createdAt = createdAt
            self.order = order
            self.sources = []
        }
    }

    @Model
    final class StoredSource {
        var id: UUID
        var title: String
        var url: String
        var snippet: String?
        var order: Int
        @Relationship(deleteRule: .nullify)
        var message: StoredMessage?

        init(id: UUID, title: String, url: String, snippet: String?, order: Int) {
            self.id = id
            self.title = title
            self.url = url
            self.snippet = snippet
            self.order = order
        }
    }

    @Model
    final class StoredFavorite {
        var id: UUID
        var messageID: UUID
        var conversationID: UUID?
        var question: String
        var answer: String
        var savedAt: Date
        @Relationship(deleteRule: .cascade, inverse: \StoredFavoriteSource.favorite)
        var sources: [StoredFavoriteSource]
        var uncitableSourceNumbersRaw: String = ""
        var answeredWithoutSearch: Bool = false
        var answeredOffline: Bool = false
        var answeredWithoutReadableSource: Bool = false
        var sourcesMayBeOffTopic: Bool = false

        init(id: UUID, messageID: UUID, conversationID: UUID?, question: String, answer: String, savedAt: Date) {
            self.id = id
            self.messageID = messageID
            self.conversationID = conversationID
            self.question = question
            self.answer = answer
            self.savedAt = savedAt
            self.sources = []
        }
    }

    @Model
    final class StoredFavoriteSource {
        var id: UUID
        var title: String
        var url: String
        var snippet: String?
        var order: Int
        @Relationship(deleteRule: .nullify)
        var favorite: StoredFavorite?

        init(id: UUID, title: String, url: String, snippet: String?, order: Int) {
            self.id = id
            self.title = title
            self.url = url
            self.snippet = snippet
            self.order = order
        }
    }
}

/// Ce qu'on écrit dans l'ancien fichier, et ce qu'on doit retrouver à l'identique.
private struct HistoryFixture {
    struct SourceSpec: Equatable { let id: UUID; let title: String; let url: String; let snippet: String? }
    struct MessageSpec: Equatable {
        let id: UUID
        let role: String
        let text: String
        let createdAt: Date
        let order: Int
        let sources: [SourceSpec]
        let uncitable: String
        let withoutSearch: Bool
    }
    struct ConversationSpec: Equatable {
        let id: UUID
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let messages: [MessageSpec]
    }
    struct FavoriteSpec: Equatable {
        let id: UUID
        let messageID: UUID
        let conversationID: UUID?
        let question: String
        let answer: String
        let savedAt: Date
        let sources: [SourceSpec]
        let uncitable: String
    }

    let conversations: [ConversationSpec]
    let favorites: [FavoriteSpec]

    static func make() -> HistoryFixture {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func source(_ n: Int, snippet: String?) -> SourceSpec {
            SourceSpec(id: UUID(), title: "Source é\(n) 🇫🇷", url: "https://exemple.test/\(n)", snippet: snippet)
        }
        // Conversation 1 : 3 échanges, sources à extrait présent et absent, écrites dans le désordre d'`order`.
        var messages: [MessageSpec] = []
        for turn in 0..<3 {
            messages.append(MessageSpec(
                id: UUID(), role: "user", text: "Question \(turn) ?", createdAt: base.addingTimeInterval(Double(turn * 10)),
                order: turn * 2, sources: [], uncitable: "", withoutSearch: false
            ))
            messages.append(MessageSpec(
                id: UUID(), role: "assistant", text: "Réponse \(turn) [1][2].\nSuite en Markdown.",
                createdAt: base.addingTimeInterval(Double(turn * 10 + 5)), order: turn * 2 + 1,
                sources: [source(turn * 10 + 1, snippet: "Extrait \(turn)"), source(turn * 10 + 2, snippet: nil)],
                uncitable: turn == 1 ? "2" : "", withoutSearch: turn == 2
            ))
        }
        let first = ConversationSpec(
            id: UUID(), title: "Première conversation", createdAt: base, updatedAt: base.addingTimeInterval(100), messages: messages
        )
        // Conversation 2 : vide de messages (cas limite : relation to-many vide).
        let empty = ConversationSpec(
            id: UUID(), title: "Sans message", createdAt: base.addingTimeInterval(200), updatedAt: base.addingTimeInterval(200), messages: []
        )
        // Conversation 3 : un seul échange, sans source.
        let single = ConversationSpec(
            id: UUID(), title: "Un échange", createdAt: base.addingTimeInterval(300), updatedAt: base.addingTimeInterval(310),
            messages: [
                MessageSpec(id: UUID(), role: "user", text: "Salut", createdAt: base.addingTimeInterval(300), order: 0, sources: [], uncitable: "", withoutSearch: false),
                MessageSpec(id: UUID(), role: "assistant", text: "Bonjour", createdAt: base.addingTimeInterval(305), order: 1, sources: [], uncitable: "", withoutSearch: true),
            ]
        )
        let answered = messages[3]
        let favorites = [
            FavoriteSpec(
                id: UUID(), messageID: answered.id, conversationID: first.id, question: "Question 1 ?", answer: answered.text,
                savedAt: base.addingTimeInterval(400), sources: answered.sources, uncitable: "2"
            ),
            // Favori d'une conversation supprimée depuis : sans conversationID, sans source.
            FavoriteSpec(
                id: UUID(), messageID: UUID(), conversationID: nil, question: "", answer: "Seule",
                savedAt: base.addingTimeInterval(500), sources: [], uncitable: ""
            ),
        ]
        return HistoryFixture(conversations: [first, empty, single], favorites: favorites)
    }
}

@MainActor
@Suite("Migration légère : l'historique d'avant le modèle compatible CloudKit reste intact")
struct CloudKitReadyMigrationTests {
    private static let storeName = "TrivaLocalStore"
    private static let locale = Locale(identifier: "fr_FR")

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrivaCloudKitMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("legacy.store")
    }

    /// Écrit le fichier avec l'ancien modèle, puis relâche le conteneur (fichier fermé).
    private func writeOldStore(_ fixture: HistoryFixture, at url: URL) throws {
        typealias Old = PreCloudKitSchema
        let schema = Schema(versionedSchema: Old.self)
        let configuration = ModelConfiguration(Self.storeName, schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        for spec in fixture.conversations {
            let conversation = Old.StoredConversation(id: spec.id, title: spec.title, createdAt: spec.createdAt, updatedAt: spec.updatedAt)
            context.insert(conversation)
            // Messages insérés à l'envers : l'ordre d'insertion ne doit rien garantir.
            for message in spec.messages.reversed() {
                let stored = Old.StoredMessage(id: message.id, roleRawValue: message.role, text: message.text, createdAt: message.createdAt, order: message.order)
                stored.uncitableSourceNumbersRaw = message.uncitable
                stored.answeredWithoutSearch = message.withoutSearch
                context.insert(stored)
                stored.conversation = conversation
                for (index, source) in message.sources.enumerated() {
                    let storedSource = Old.StoredSource(id: source.id, title: source.title, url: source.url, snippet: source.snippet, order: index)
                    context.insert(storedSource)
                    storedSource.message = stored
                }
            }
        }
        for spec in fixture.favorites {
            let favorite = Old.StoredFavorite(
                id: spec.id, messageID: spec.messageID, conversationID: spec.conversationID,
                question: spec.question, answer: spec.answer, savedAt: spec.savedAt
            )
            favorite.uncitableSourceNumbersRaw = spec.uncitable
            context.insert(favorite)
            for (index, source) in spec.sources.enumerated() {
                let storedSource = Old.StoredFavoriteSource(id: source.id, title: source.title, url: source.url, snippet: source.snippet, order: index)
                context.insert(storedSource)
                storedSource.favorite = favorite
            }
        }
        try context.save()
    }

    private func openCurrent(at url: URL) throws -> ModelContainer {
        let schema = Schema(TrivaModelContainer.models)
        let configuration = ModelConfiguration(Self.storeName, schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func prepare() throws -> (url: URL, fixture: HistoryFixture) {
        let url = try makeTemporaryStoreURL()
        let fixture = HistoryFixture.make()
        try writeOldStore(fixture, at: url)
        return (url, fixture)
    }

    /// Relit tout ce que l'app lit, par les magasins réels, depuis le conteneur donné.
    private func readBack(_ container: ModelContainer) throws -> (conversations: [HistoryFixture.ConversationSpec], favorites: [HistoryFixture.FavoriteSpec]) {
        let history = ChatHistoryStore(container: container, locale: Self.locale)
        let favorites = FavoritesStore(container: container, locale: Self.locale)
        let conversations = try history.conversations().map { conversation in
            HistoryFixture.ConversationSpec(
                id: conversation.id, title: conversation.title, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt,
                messages: conversation.orderedMessages.map { message in
                    HistoryFixture.MessageSpec(
                        id: message.id, role: message.roleRawValue, text: message.text, createdAt: message.createdAt, order: message.order,
                        sources: message.orderedSources.map { .init(id: $0.id, title: $0.title, url: $0.url, snippet: $0.snippet) },
                        uncitable: message.uncitableSourceNumbersRaw, withoutSearch: message.answeredWithoutSearch
                    )
                }
            )
        }
        let marked = try favorites.favorites().map { favorite in
            HistoryFixture.FavoriteSpec(
                id: favorite.id, messageID: favorite.messageID, conversationID: favorite.conversationID,
                question: favorite.question, answer: favorite.answer, savedAt: favorite.savedAt,
                sources: favorite.orderedSources.map { .init(id: $0.id, title: $0.title, url: $0.url, snippet: $0.snippet) },
                uncitable: favorite.uncitableSourceNumbersRaw
            )
        }
        return (conversations, marked)
    }

    private func sortedByID(_ conversations: [HistoryFixture.ConversationSpec]) -> [HistoryFixture.ConversationSpec] {
        conversations.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    @Test("Le fichier d'avant s'ouvre avec le nouveau modèle, sans erreur ni plan de migration")
    func oldStoreOpens() throws {
        let (url, _) = try prepare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try openCurrent(at: url)
    }

    @Test("Conversations, messages, ordre, textes, dates, identifiants et sources : identiques")
    func conversationsAreIdentical() throws {
        let (url, fixture) = try prepare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let read = try readBack(try openCurrent(at: url))

        #expect(read.conversations.count == 3)
        #expect(sortedByID(read.conversations) == sortedByID(fixture.conversations))
        #expect(read.conversations.reduce(0) { $0 + $1.messages.count } == 8)
        #expect(read.conversations.flatMap(\.messages).reduce(0) { $0 + $1.sources.count } == 6)
    }

    @Test("Favoris et leurs sources : identiques, y compris le favori sans conversation")
    func favoritesAreIdentical() throws {
        let (url, fixture) = try prepare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let read = try readBack(try openCurrent(at: url))

        #expect(read.favorites.count == 2)
        #expect(Set(read.favorites.map(\.id)) == Set(fixture.favorites.map(\.id)))
        for expected in fixture.favorites {
            let found = try #require(read.favorites.first { $0.id == expected.id })
            #expect(found == expected)
        }
    }

    @Test("La conversation sans message se relit vide, et les relations restent des inverses l'une de l'autre")
    func emptyConversationAndInverses() throws {
        let (url, fixture) = try prepare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let container = try openCurrent(at: url)
        let context = ModelContext(container)

        let emptyID = try #require(fixture.conversations.first { $0.messages.isEmpty }?.id)
        let conversations = try context.fetch(FetchDescriptor<StoredConversation>())
        let empty = try #require(conversations.first { $0.id == emptyID })
        #expect(empty.orderedMessages.isEmpty)

        for message in try context.fetch(FetchDescriptor<StoredMessage>()) {
            let owner = try #require(message.conversation)
            #expect(owner.orderedMessages.contains { $0.id == message.id })
            for source in message.orderedSources {
                #expect(source.message?.id == message.id)
            }
        }
    }

    @Test("Écrire sur le fichier migré, le fermer, le rouvrir : tout est là (aucune nouvelle migration)")
    func writesSurviveAReopen() throws {
        let (url, fixture) = try prepare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let newConversationID: UUID
        do {
            let container = try openCurrent(at: url)
            let history = ChatHistoryStore(container: container, locale: Self.locale)
            let conversation = try history.createConversation(firstQuestion: "Nouvelle question ?", now: historyDate(1_000))
            newConversationID = conversation.id
            try history.appendUserMessage(to: conversation, text: "Nouvelle question ?", now: historyDate(1_000))
            try history.appendAssistantMessage(
                to: conversation, text: "Nouvelle réponse [1]", sources: historyMakeSources(2), notes: StoredAnswerNotes(), now: historyDate(1_001)
            )
        }

        let read = try readBack(try openCurrent(at: url))

        #expect(read.conversations.count == 4)
        let added = try #require(read.conversations.first { $0.id == newConversationID })
        #expect(added.messages.map(\.role) == ["user", "assistant"])
        #expect(added.messages.last?.sources.map(\.title) == ["Source 1", "Source 2"])
        let untouched = read.conversations.filter { $0.id != newConversationID }
        #expect(sortedByID(untouched) == sortedByID(fixture.conversations))
    }

    @Test("Supprimer une conversation migrée supprime toujours ses messages et ses sources (cascade intacte)")
    func cascadeStillWorksAfterMigration() throws {
        let (url, fixture) = try prepare()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let target = try #require(fixture.conversations.first { !$0.messages.isEmpty && $0.messages.count > 2 })
        do {
            let history = ChatHistoryStore(container: try openCurrent(at: url), locale: Self.locale)
            let conversation = try #require(try history.conversation(with: target.id))
            try history.delete(conversation)
        }

        let context = ModelContext(try openCurrent(at: url))
        let messageIDs = Set(try context.fetch(FetchDescriptor<StoredMessage>()).map(\.id))
        let sourceIDs = Set(try context.fetch(FetchDescriptor<StoredSource>()).map(\.id))
        #expect(messageIDs.isDisjoint(with: target.messages.map(\.id)))
        #expect(sourceIDs.isDisjoint(with: target.messages.flatMap(\.sources).map(\.id)))
        // Les autres conversations ne perdent rien : 2 messages de « Un échange ».
        #expect(messageIDs.count == 2)
        // Les favoris survivent à la suppression de l'historique (copie autonome).
        #expect(try context.fetch(FetchDescriptor<StoredFavorite>()).count == 2)
    }
}
