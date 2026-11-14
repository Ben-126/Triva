//
//  ChatViewModelBackgroundGenerationTests.swift
//  TrivaTests
//
//  Mission C5 (décision R3-2 de Ben) : la réponse continue en arrière-plan quand on ouvre une
//  autre conversation, et finit dans SA conversation.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
    /// Fil B déjà dans l'historique (une question, une réponse) : la conversation qu'on ouvre.
    private func makeStoredConversationB(in stores: PersistenceStores) throws -> StoredConversation {
        let conversation = try stores.history.createConversation(firstQuestion: "Question B")
        try stores.history.appendUserMessage(to: conversation, text: "Question B")
        try stores.history.appendAssistantMessage(to: conversation, text: "Réponse B.", sources: [])
        return conversation
    }

    /// Lance A, laisse streamer « Début A », et renvoie l'identifiant de sa conversation.
    private func startGeneratingA(
        _ viewModel: ChatViewModel,
        _ aiProvider: ControllableStreamingAIGenerating
    ) async -> (UUID, AsyncThrowingStream<String, Error>.Continuation)? {
        viewModel.startSend(query: "Question A")
        guard let continuation = await waitForContinuation(aiProvider),
              let conversationID = viewModel.currentConversationID else { return nil }
        continuation.yield("Début A")
        await waitUntil("1er snapshot de A") { viewModel.messages.last?.text == "Début A" }
        return (conversationID, continuation)
    }

    private func storedAnswerTexts(_ stores: PersistenceStores, _ id: UUID) throws -> [String] {
        try stores.history.conversation(with: id)?.orderedMessages.filter { $0.role == .assistant }.map(\.text) ?? []
    }

    @Test("Ouvrir B pendant que A génère : A finit et s'enregistre dans A, B reste propre")
    func openingAnotherConversationLetsTheGenerationFinishInItsOwnConversation() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingA(viewModel, aiProvider) else { return }

        #expect(viewModel.loadConversation(id: conversationB.id))
        #expect(!viewModel.isGenerating)
        #expect(viewModel.currentConversationID == conversationB.id)
        continuation.yield("Début A et la fin de A.")
        continuation.finish()
        await waitUntil("réponse de A enregistrée") { (try? self.storedAnswerTexts(stores, idA))?.count == 1 }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchange == nil }

        #expect(try storedAnswerTexts(stores, idA) == ["Début A et la fin de A."])
        #expect(viewModel.messages.map(\.text) == ["Question B", "Réponse B."])
        #expect(viewModel.messages.allSatisfy { $0.status != .streaming && !$0.isStreaming })
        #expect(viewModel.errorDescription == nil)
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundExchange == nil)
        #expect(try storedAnswerTexts(stores, conversationB.id) == ["Réponse B."])
    }

    @Test("A génère, on ouvre B puis C : A continue en arrière-plan et finit dans A (revue VE2c)")
    func openingASecondOtherConversationKeepsTheBackgroundGeneration() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let conversationC = try stores.history.createConversation(firstQuestion: "Question C")
        try stores.history.appendUserMessage(to: conversationC, text: "Question C")
        try stores.history.appendAssistantMessage(to: conversationC, text: "Réponse C.", sources: [])
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingA(viewModel, aiProvider) else { return }

        #expect(viewModel.loadConversation(id: conversationB.id))
        #expect(viewModel.loadConversation(id: conversationC.id))
        #expect(viewModel.backgroundExchange?.conversationID == idA)
        continuation.yield("Début A et la fin de A.")
        continuation.finish()
        await waitUntil("réponse de A enregistrée") { (try? self.storedAnswerTexts(stores, idA))?.count == 1 }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchange == nil }

        #expect(try storedAnswerTexts(stores, idA) == ["Début A et la fin de A."])
        #expect(viewModel.messages.map(\.text) == ["Question C", "Réponse C."])
        #expect(try storedAnswerTexts(stores, conversationC.id) == ["Réponse C."])
    }

    @Test("Rouvrir A pendant sa génération : on retrouve le fil vivant, qui finit normalement")
    func reopeningTheGeneratingConversationResumesItsLiveThread() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingA(viewModel, aiProvider) else { return }
        viewModel.loadConversation(id: conversationB.id)
        continuation.yield("Début A, suite.")
        await waitUntil("suite reçue en arrière-plan") { viewModel.backgroundExchange?.messages.last?.text == "Début A, suite." }
        #expect(viewModel.messages.map(\.text) == ["Question B", "Réponse B."])

        #expect(viewModel.loadConversation(id: idA))

        #expect(viewModel.isGenerating)
        #expect(viewModel.currentConversationID == idA)
        #expect(viewModel.messages.last?.text == "Début A, suite.")
        continuation.yield("Début A, suite et fin.")
        continuation.finish()
        await waitUntil("A terminée") { !viewModel.isGenerating }

        #expect(viewModel.messages.last?.text == "Début A, suite et fin.")
        #expect(viewModel.messages.last?.status == .completed)
        #expect(try storedAnswerTexts(stores, idA) == ["Début A, suite et fin."])
    }

    @Test("Rouvrir A une fois terminée : elle est relue depuis l'historique, sans génération")
    func reopeningAFinishedConversationReadsTheHistory() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingA(viewModel, aiProvider) else { return }
        viewModel.loadConversation(id: conversationB.id)
        continuation.yield("Réponse finale de A.")
        continuation.finish()
        await waitUntil("A enregistrée") { (try? self.storedAnswerTexts(stores, idA))?.count == 1 }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchange == nil }

        #expect(viewModel.loadConversation(id: idA))

        #expect(!viewModel.isGenerating)
        #expect(viewModel.messages.map(\.text) == ["Question A", "Réponse finale de A."])
        #expect(viewModel.messages.last?.status == .completed)
    }

    @Test("Stop arrête la génération laissée en arrière-plan : texte partiel gardé dans A, B intact")
    func stopCancelsTheBackgroundGeneration() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, _) = await startGeneratingA(viewModel, aiProvider) else { return }
        viewModel.loadConversation(id: conversationB.id)

        viewModel.stop()
        await waitUntil("partiel de A enregistré") { (try? self.storedAnswerTexts(stores, idA)) == ["Début A"] }

        #expect(viewModel.backgroundExchange == nil)
        #expect(viewModel.messages.map(\.text) == ["Question B", "Réponse B."])
        #expect(!viewModel.isGenerating)
    }

    @Test("A supprimée pendant sa génération en arrière-plan : aucun plantage, rien n'est écrit")
    func deletingTheBackgroundConversationWritesNothing() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingA(viewModel, aiProvider) else { return }
        viewModel.loadConversation(id: conversationB.id)

        let conversationA = try #require(try stores.history.conversation(with: idA))
        try stores.history.delete(conversationA)
        viewModel.conversationWasDeleted(id: idA)
        continuation.yield("Début A et fin.")
        continuation.finish()
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchange == nil }
        try await Task.sleep(for: .milliseconds(50))

        #expect(try stores.history.conversation(with: idA) == nil)
        #expect(try stores.history.conversations().map(\.id) == [conversationB.id])
        #expect(viewModel.messages.map(\.text) == ["Question B", "Réponse B."])
        #expect(viewModel.persistenceErrorDescription == nil)
    }

    @Test("Question envoyée dans B pendant que A génère : A est arrêtée (partiel gardé), B répond, rien ne se mélange")
    func sendingElsewhereStopsTheBackgroundGeneration() async throws {
        let stores = try PersistenceStores()
        let conversationB = try makeStoredConversationB(in: stores)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, _) = await startGeneratingA(viewModel, aiProvider) else { return }
        viewModel.loadConversation(id: conversationB.id)

        viewModel.startSend(query: "Nouvelle question B")
        await waitUntil("2e génération lancée") { aiProvider.receivedPrompts.count == 2 }
        guard let continuationB = aiProvider.continuation else { return }
        continuationB.yield("Réponse à B.")
        continuationB.finish()
        await waitUntil("B terminée") { !viewModel.isGenerating }

        #expect(viewModel.backgroundExchange == nil)
        #expect(viewModel.messages.map(\.text) == ["Question B", "Réponse B.", "Nouvelle question B", "Réponse à B."])
        #expect(try storedAnswerTexts(stores, idA) == ["Début A"])
        #expect(try storedAnswerTexts(stores, conversationB.id) == ["Réponse B.", "Réponse à B."])
    }
}
