//
//  StoredAnswerNotesMigrationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Triva

// Mission E1a, point 4 : les champs ajoutés à `StoredMessage` et `StoredFavorite` ne doivent pas
// casser les bases existantes. On écrit un VRAI fichier SQLite avec le schéma tel qu'il était au
// commit fc5a4be (copies des cinq modèles, mêmes noms de classes, sans les nouveaux champs), puis on le
// rouvre avec le schéma actuel, par le chemin du conteneur de l'app (`Schema(TrivaModelContainer.models)`,
// sans plan de migration : migration légère automatique). Fichier dans un dossier temporaire, JAMAIS
// le store de l'utilisateur.

/// Le schéma d'avant la mission E1a. Les classes portent les noms des modèles actuels (c'est ce qui
/// désigne l'entité en base) ; enveloppées dans un `enum` pour ne pas entrer en collision avec eux.
private enum LegacySchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
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

@MainActor
@Suite("Migration légère — anciens messages et favoris sans les champs de la mission E1a")
struct StoredAnswerNotesMigrationTests {
    private static let conversationID = UUID()
    private static let messageID = UUID()
    private static let favoriteMessageID = UUID()
    private static let storeName = "TrivaLocalStore"

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrivaMigrationTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("legacy.store")
    }

    /// Écrit une base à l'ancien schéma, puis relâche le conteneur (fichier fermé).
    private func writeLegacyStore(at url: URL) throws {
        let schema = Schema(versionedSchema: LegacySchema.self)
        let configuration = ModelConfiguration(Self.storeName, schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let conversation = LegacySchema.StoredConversation(id: Self.conversationID, title: "Ancienne", createdAt: date, updatedAt: date)
        context.insert(conversation)
        let question = LegacySchema.StoredMessage(id: UUID(), roleRawValue: "user", text: "Question", createdAt: date, order: 0)
        let answer = LegacySchema.StoredMessage(id: Self.messageID, roleRawValue: "assistant", text: "Réponse[1][2].", createdAt: date, order: 1)
        context.insert(question)
        context.insert(answer)
        question.conversation = conversation
        answer.conversation = conversation
        for (index, title) in ["Lue", "Non lue"].enumerated() {
            let source = LegacySchema.StoredSource(id: UUID(), title: title, url: "https://exemple.test/\(index)", snippet: nil, order: index)
            context.insert(source)
            source.message = answer
        }
        let favorite = LegacySchema.StoredFavorite(
            id: UUID(), messageID: Self.favoriteMessageID, conversationID: Self.conversationID,
            question: "Question", answer: "Réponse[1].", savedAt: date
        )
        context.insert(favorite)
        let favoriteSource = LegacySchema.StoredFavoriteSource(id: UUID(), title: "Lue", url: "https://exemple.test/0", snippet: nil, order: 0)
        context.insert(favoriteSource)
        favoriteSource.favorite = favorite
        try context.save()
    }

    private func openCurrent(at url: URL) throws -> ModelContainer {
        let schema = Schema(TrivaModelContainer.models)
        let configuration = ModelConfiguration(Self.storeName, schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    @Test("Un fichier écrit avant les nouveaux champs s'ouvre : mentions vides, conversation restaurée, favori lisible")
    func oldStoreOpensWithEmptyNotes() throws {
        let url = try makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacyStore(at: url)

        let container = try openCurrent(at: url)
        let history = ChatHistoryStore(container: container, locale: Locale(identifier: "fr_FR"))
        let favorites = FavoritesStore(container: container, locale: Locale(identifier: "fr_FR"))

        let conversation = try #require(try history.conversation(with: Self.conversationID))
        let answer = try #require(conversation.orderedMessages.last)
        #expect(answer.id == Self.messageID)
        #expect(answer.text == "Réponse[1][2].")
        #expect(answer.orderedSources.map(\.title) == ["Lue", "Non lue"])
        #expect(answer.answerNotes == StoredAnswerNotes())
        #expect(answer.uncitableSourceNumbersRaw == "")

        let favorite = try #require(try favorites.favorite(forMessageID: Self.favoriteMessageID))
        #expect(favorite.uncitableSourceNumbers.isEmpty)
        let content = FavoritePresentation.detailContent(copying: favorite)
        #expect(content.sources.count == 1)
        #expect(content.uncitableSourceNumbers.isEmpty)

        // Les nouveaux champs s'écrivent ensuite normalement sur ce même fichier.
        let newAnswer = try history.appendAssistantMessage(
            to: conversation, text: "Suite", notes: StoredAnswerNotes(uncitableSourceNumbers: [2], answeredWithoutSearch: true)
        )
        #expect(newAnswer.answerNotes.uncitableSourceNumbers == [2])
    }

    /// Vérification VE1 : les autres tests relisent les mentions dans le MÊME conteneur (en mémoire).
    /// Ici, aller-retour réel par le fichier : écriture, conteneur relâché, conteneur NEUF, relecture.
    @Test("Les mentions écrites sur un fichier migré se relisent depuis un conteneur neuf")
    func notesSurviveAFreshContainer() throws {
        let url = try makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacyStore(at: url)
        let written = StoredAnswerNotes(
            uncitableSourceNumbers: [2, 3], answeredWithoutSearch: true,
            answeredOffline: true, answeredWithoutReadableSource: true
        )
        let favoriteID = UUID()
        let answerID: UUID
        do {
            let container = try openCurrent(at: url)
            let history = ChatHistoryStore(container: container, locale: Locale(identifier: "fr_FR"))
            let favorites = FavoritesStore(container: container, locale: Locale(identifier: "fr_FR"))
            let conversation = try #require(try history.conversation(with: Self.conversationID))
            answerID = try history.appendAssistantMessage(to: conversation, text: "Suite", notes: written).id
            try favorites.mark(
                messageID: favoriteID, conversationID: Self.conversationID,
                question: "Question", answer: "Suite", uncitableSourceNumbers: [3]
            )
        }

        let reopened = ModelContext(try openCurrent(at: url))
        let messages = try reopened.fetch(FetchDescriptor<StoredMessage>())
        let answer = try #require(messages.first { $0.id == answerID })
        #expect(answer.answerNotes == written)
        let storedFavorites = try reopened.fetch(FetchDescriptor<StoredFavorite>())
        let favorite = try #require(storedFavorites.first { $0.messageID == favoriteID })
        #expect(favorite.uncitableSourceNumbers == [3])
    }

    @Test("La conversation ancienne se rouvre dans le chat, sans mention")
    func oldConversationLoadsInTheChat() throws {
        let url = try makeTemporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacyStore(at: url)
        let history = ChatHistoryStore(container: try openCurrent(at: url), locale: Locale(identifier: "fr_FR"))
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
        let model = ChatViewModel(
            resolveProvider: { ChainAIProvider() }, resolveFailoverManager: { manager },
            readResponseMode: { .quick }, historyStore: history
        )

        #expect(model.loadConversation(id: Self.conversationID))

        let restored = try #require(model.messages.last)
        #expect(restored.status == .completed)
        #expect(restored.sources.count == 2)
        #expect(restored.uncitableSourceNumbers.isEmpty)
        #expect(!restored.answeredWithoutSearch && !restored.answeredOffline && !restored.answeredWithoutReadableSource)
    }
}
