//
//  ChatViewModelPersistenceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
    // MARK: - Historique persistant (1.9)

    @Test("La question est écrite à l'envoi, la réponse UNE fois à la fin (aucune écriture par snapshot)")
    func questionIsSavedAtSendAndTheAnswerOnceAtTheEnd() async throws {
        let stores = try PersistenceStores()
        let results = [Self.makeResult(title: "Japon", url: "https://ja.example", content: "Tokyo")]
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(results)),
            stores: stores
        )

        let task = Task { await viewModel.send(query: "Quelle est la capitale du Japon ?") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        let conversation = try #require(try stores.onlyConversation())
        #expect(conversation.orderedMessages.map(\.role) == [.user])
        #expect(viewModel.currentConversationID == conversation.id)
        let revisionWhileStreaming = stores.history.revision

        for snapshot in ["Tokyo", "Tokyo est", "Tokyo est la capitale[1]."] {
            continuation.yield(snapshot)
            await waitUntil("snapshot « \(snapshot) » affiché") { viewModel.messages.last?.text == snapshot }
        }
        #expect(stores.history.revision == revisionWhileStreaming)

        continuation.finish()
        await task.value

        #expect(stores.history.revision == revisionWhileStreaming + 1)
        let saved = try #require(try stores.history.conversation(with: conversation.id)).orderedMessages
        #expect(saved.map(\.role) == [.user, .assistant])
        #expect(saved.last?.text == "Tokyo est la capitale[1].")
        #expect(saved.last?.orderedSources.map(\.url) == results.map(\.url))
        let answer = try #require(viewModel.messages.last)
        #expect(answer.storedMessageID == saved.last?.id)
        #expect(answer.storedConversationID == conversation.id)
    }

    @Test("Une réponse arrêtée est persistée telle quelle ; une réponse vide ne l'est jamais")
    func stoppedAnswerIsSavedButAnEmptyOneIsNot() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let task = Task { await viewModel.send(query: "Question longue") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Début de réponse")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Début de réponse" }
        task.cancel()
        await task.value

        let stopped = try #require(try stores.onlyConversation())
        #expect(stopped.orderedMessages.map(\.text) == ["Question longue", "Début de réponse"])

        let emptyStores = try PersistenceStores()
        let emptyProvider = MockStreamingAIGenerating(chunks: [])
        let emptyViewModel = makeViewModel(resolveProvider: { emptyProvider }, stores: emptyStores)
        await emptyViewModel.send(query: "Question sans réponse")
        let unanswered = try #require(try emptyStores.onlyConversation())
        #expect(unanswered.orderedMessages.map(\.role) == [.user])
    }

    @Test("Une conversation relue s'affiche terminée, sources dans l'ordre, et la suite s'y ajoute avec son contexte")
    func reloadedConversationIsShownAndContinued() async throws {
        let stores = try PersistenceStores()
        let conversation = try stores.history.createConversation(firstQuestion: "Qui a écrit Germinal ?")
        try stores.history.appendUserMessage(to: conversation, text: "Qui a écrit Germinal ?")
        let attachmentSource = Self.makeResult(
            title: "notes.txt", url: UploadsSearchResultBuilder.sourceURL(for: UUID()), content: "Mes notes de lecture."
        )
        let webSource = Self.makeResult(title: "Germinal", url: "https://fr.wikipedia.org/wiki/Germinal", content: "Roman d'Émile Zola.")
        let storedAnswer = try stores.history.appendAssistantMessage(
            to: conversation, text: "<think>Je vérifie.</think>Émile Zola[2].", sources: [attachmentSource, webSource]
        )
        let aiProvider = MockStreamingAIGenerating(chunks: ["En 1885."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let loaded = viewModel.loadConversation(id: conversation.id)

        #expect(loaded)
        #expect(viewModel.currentConversationID == conversation.id)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        let restored = viewModel.messages[1]
        #expect(restored.status == .completed)
        #expect(restored.storedMessageID == storedAnswer.id)
        #expect(restored.sources.map(\.url) == [attachmentSource.url, webSource.url])
        #expect(restored.attachmentSourceCount == 1)
        #expect(restored.segments.body == "Émile Zola[2].")

        await viewModel.send(query: "Et en quelle année ?")

        let classifierHistory = try #require(taggedBlock("conversation_history", in: aiProvider.classifierPrompts.last))
        #expect(classifierHistory.contains("Qui a écrit Germinal ?"))
        #expect(classifierHistory.contains("Émile Zola"))
        #expect(!classifierHistory.contains("Je vérifie"))
        let continued = try #require(try stores.onlyConversation())
        #expect(continued.id == conversation.id)
        #expect(continued.orderedMessages.count == 4)
    }

    @Test("Recharger une conversation introuvable échoue sans toucher au fil, avec un message")
    func loadingAMissingConversationKeepsTheThread() async throws {
        let stores = try PersistenceStores()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        await viewModel.send(query: "Bonjour")
        let thread = viewModel.messages

        let loaded = viewModel.loadConversation(id: UUID())

        #expect(!loaded)
        #expect(viewModel.persistenceErrorDescription == ChatViewModel.missingConversationMessage)
        #expect(viewModel.messages == thread)
    }

    @Test("Supprimer la conversation du fil depuis la Bibliothèque fait repartir le chat à neuf ; une autre suppression n'y touche pas")
    func deletingTheOpenConversationResetsTheChat() async throws {
        let stores = try PersistenceStores()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        await viewModel.send(query: "Bonjour")
        let openID = try #require(viewModel.currentConversationID)

        viewModel.conversationWasDeleted(id: UUID())
        #expect(viewModel.messages.count == 2)

        try stores.history.delete(try #require(try stores.history.conversation(with: openID)))
        viewModel.conversationWasDeleted(id: openID)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.currentConversationID == nil)

        await viewModel.send(query: "Nouvelle question")
        let fresh = try #require(try stores.onlyConversation())
        #expect(fresh.id != openID)
        #expect(viewModel.currentConversationID == fresh.id)
    }

    // MARK: - Nouvelle conversation (décision 1 de Ben)

    @Test("« Nouvelle conversation » en plein flux : arrêt sans erreur, fil vidé, réponse partielle dans l'ANCIENNE conversation")
    func newConversationStopsTheAnswerAndKeepsItInTheOldOne() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let task = Task { await viewModel.send(query: "Première question") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Réponse partielle")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Réponse partielle" }
        let oldID = try #require(viewModel.currentConversationID)

        viewModel.startNewConversation()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.currentConversationID == nil)
        // L'échange annulé finit de se dérouler : rien ne fuit dans le nouveau
        // fil, sa réponse partielle rejoint l'ancienne conversation.
        await task.value
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.errorDescription == nil)
        let old = try #require(try stores.history.conversation(with: oldID))
        #expect(old.orderedMessages.map(\.text) == ["Première question", "Réponse partielle"])

        let nextTask = Task { await viewModel.send(query: "Deuxième question") }
        await waitUntil("2e flux ouvert") { aiProvider.receivedPrompts.count == 2 }
        aiProvider.continuation?.yield("Autre réponse")
        aiProvider.continuation?.finish()
        await nextTask.value

        #expect(viewModel.messages.map(\.text) == ["Deuxième question", "Autre réponse"])
        #expect(try stores.history.conversations().count == 2)
        #expect(viewModel.currentConversationID != oldID)
        // Le 2e prompt ne contient rien de l'ancienne conversation.
        #expect(aiProvider.receivedPrompts.last?.contains("Première question") == false)
    }

    // MARK: - Favoris (1.10)

    @Test("Un favori est rattaché à l'id PERSISTANT de la réponse, jamais à l'UUID de la bulle ; retirer le défait")
    func favoriteIsKeyedToTheStoredMessage() async throws {
        let stores = try PersistenceStores()
        let results = [Self.makeResult(title: "Japon", url: "https://ja.example", content: "Tokyo")]
        let aiProvider = MockStreamingAIGenerating(chunks: ["<think>Je cherche.</think>Tokyo[1]."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(results)),
            stores: stores
        )
        await viewModel.send(query: "Capitale du Japon ?")
        let answer = try #require(viewModel.messages.last)
        let storedID = try #require(answer.storedMessageID)
        #expect(storedID != answer.id)
        #expect(viewModel.canToggleFavorite(answer))
        #expect(!viewModel.canToggleFavorite(viewModel.messages[0]))
        #expect(!viewModel.isFavorite(answer))

        viewModel.toggleFavorite(messageID: answer.id)

        #expect(viewModel.isFavorite(answer))
        #expect(try stores.favorites.favoritedMessageIDs() == [storedID])
        let favorite = try #require(try stores.favorites.favorite(forMessageID: storedID))
        #expect(favorite.question == "Capitale du Japon ?")
        #expect(favorite.answer == "<think>Je cherche.</think>Tokyo[1].")
        #expect(favorite.conversationID == viewModel.currentConversationID)
        #expect(favorite.orderedSources.map(\.url) == results.map(\.url))

        viewModel.toggleFavorite(messageID: answer.id)

        #expect(!viewModel.isFavorite(answer))
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
    }

    @Test("Pas de favori pendant le streaming, ni sans historique (rien de persistant à quoi le rattacher)")
    func favoriteIsRefusedWhileStreamingAndWithoutHistory() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        let task = Task { await viewModel.send(query: "Question") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Début")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Début" }
        let streaming = try #require(viewModel.messages.last)

        #expect(!viewModel.canToggleFavorite(streaming))
        viewModel.toggleFavorite(messageID: streaming.id)
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
        continuation.finish()
        await task.value

        let plainProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let withoutHistory = makeViewModel(resolveProvider: { plainProvider })
        await withoutHistory.send(query: "Question")
        let answer = try #require(withoutHistory.messages.last)
        #expect(answer.storedMessageID == nil)
        #expect(!withoutHistory.canToggleFavorite(answer))
    }

    @Test("L'étoile survit au rechargement de la conversation, et se retire depuis le fil relu")
    func favoriteSurvivesAReload() async throws {
        let stores = try PersistenceStores()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        await viewModel.send(query: "Question")
        viewModel.toggleFavorite(messageID: try #require(viewModel.messages.last?.id))
        let conversationID = try #require(viewModel.currentConversationID)

        viewModel.startNewConversation()
        let loaded = viewModel.loadConversation(id: conversationID)

        #expect(loaded)
        let reloaded = try #require(viewModel.messages.last)
        #expect(viewModel.isFavorite(reloaded))
        viewModel.toggleFavorite(messageID: reloaded.id)
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
    }

}
