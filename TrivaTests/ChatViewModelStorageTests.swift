//
//  ChatViewModelStorageTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

extension ChatViewModelTests.PersistenceStores {
    /// Stores branchés sur un `TrivaStorage` donné (par exemple indisponible).
    init(storage: TrivaStorage) {
        history = ChatHistoryStore(storage: storage, locale: Locale(identifier: "fr_FR"))
        favorites = FavoritesStore(storage: storage, locale: Locale(identifier: "fr_FR"))
    }
}

extension ChatViewModelTests {
    // MARK: - Base locale inaccessible (K8)

    @Test("Base inaccessible : la recherche répond quand même, et le chat dit que l'échange n'est pas enregistré")
    func searchStillAnswersWhenTheStorageIsUnavailable() async throws {
        let storage = TrivaStorage(
            opener: { throw TrivaModelContainerError.creationFailed("panne simulée") },
            retryDelaysMilliseconds: [],
            pause: { _ in }
        )
        let stores = ChatViewModelTests.PersistenceStores(storage: storage)
        let results = [Self.makeResult(title: "Japon", url: "https://ja.example", content: "Tokyo")]
        let aiProvider = MockStreamingAIGenerating(chunks: ["Tokyo est la capitale[1]."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(results)),
            stores: stores
        )
        #expect(!storage.isAvailable)

        await viewModel.send(query: "Quelle est la capitale du Japon ?")

        #expect(viewModel.messages.last?.text == "Tokyo est la capitale[1].")
        #expect(viewModel.messages.last?.status == .completed)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.persistenceErrorDescription == ChatHistoryStoreError.storageUnavailable.userFacingMessage)
        #expect(viewModel.currentConversationID == nil)
        // Rien n'a été écrit « dans le vide » : le conteneur de réserve est resté vide.
        let reserve = ModelContext(storage.container)
        #expect(try reserve.fetchCount(FetchDescriptor<StoredConversation>()) == 0)
    }

    // MARK: - Effacement pendant une réponse (R4-2)

    @Test("« Tout effacer » pendant une réponse : la conversation effacée ne revient PAS avec la réponse partielle")
    func eraseAllDuringAnAnswerDoesNotResurrectTheConversation() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let task = Task { await viewModel.send(query: "Question longue") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Réponse partielle")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Réponse partielle" }
        let openID = try #require(viewModel.currentConversationID)
        #expect(try stores.history.conversations().count == 1)

        // Ce que fait « Tout effacer » : vider la base, puis le coordinateur vide le fil ouvert.
        try stores.history.deleteAll()
        viewModel.conversationWasDeleted(id: openID)
        continuation.finish()
        await task.value

        #expect(try stores.history.conversations().isEmpty)
        #expect(viewModel.persistenceErrorDescription == nil)
        #expect(viewModel.currentConversationID == nil)
    }

    @Test("Suppression de la conversation depuis la Bibliothèque pendant une réponse : elle ne revient pas non plus")
    func deletingTheConversationDuringAnAnswerDoesNotResurrectIt() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let task = Task { await viewModel.send(query: "Question longue") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Réponse partielle")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Réponse partielle" }
        let openID = try #require(viewModel.currentConversationID)

        try stores.history.delete(try #require(try stores.history.conversation(with: openID)))
        viewModel.conversationWasDeleted(id: openID)
        continuation.finish()
        await task.value

        #expect(try stores.history.conversations().isEmpty)
        #expect(viewModel.persistenceErrorDescription == nil)
    }
}
