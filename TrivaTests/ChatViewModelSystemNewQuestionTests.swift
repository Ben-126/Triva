//
//  ChatViewModelSystemNewQuestionTests.swift
//  TrivaTests
//
//  Chantier 2.1 (missions B2 puis NC) : « nouvelle conversation » (bouton, ⇧⌘O, widget, Siri, bouton Action,
//  `triva://new`) : UN seul chemin, la réponse en cours finit en arrière-plan, les fichiers joints partent ; et
//  demande de clavier honorée même quand la vue n'était pas montée.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
    /// Lance « Question A », laisse streamer « Début A », rend l'identifiant de sa conversation.
    private func startGeneratingQuestionA(
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

    private func answerTexts(_ stores: PersistenceStores, _ id: UUID) throws -> [String] {
        try stores.history.conversation(with: id)?.orderedMessages.filter { $0.role == .assistant }.map(\.text) ?? []
    }

    // MARK: - Demande de clavier en attente

    @Test("Une demande de clavier faite avant l'apparition de la vue est honorée une seule fois")
    func pendingFocusRequestIsHonoredOnce() throws {
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: []) })
        #expect(viewModel.consumePendingFocusRequest() == false)

        viewModel.startNewConversationFromSystem()

        #expect(viewModel.consumePendingFocusRequest() == true)
        #expect(viewModel.consumePendingFocusRequest() == false)
    }

    @Test("Plusieurs demandes avant l'apparition : un seul focus ; une demande ultérieure en redonne un")
    func severalRequestsBeforeAppearingGiveOneFocus() throws {
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: []) })
        viewModel.startNewConversationFromSystem()
        viewModel.startNewConversationFromUser()

        #expect(viewModel.consumePendingFocusRequest() == true)
        #expect(viewModel.consumePendingFocusRequest() == false)

        viewModel.startNewConversationFromUser()
        #expect(viewModel.consumePendingFocusRequest() == true)
    }

    @Test("Demande déjà servie par la vue montée : l'apparition suivante ne redonne pas le clavier")
    func servedRequestIsNotRepeatedOnNextAppearance() throws {
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: []) })
        viewModel.startNewConversationFromUser()
        #expect(viewModel.consumePendingFocusRequest() == true)  // via onChange de la vue montée
        #expect(viewModel.consumePendingFocusRequest() == false) // via onAppear / task d'une vue recréée
    }

    @Test("Une remise à zéro automatique (conversation supprimée) ne demande pas le clavier")
    func automaticResetRequestsNoFocus() throws {
        let stores = try PersistenceStores()
        let conversation = try stores.history.createConversation(firstQuestion: "Q")
        try stores.history.appendUserMessage(to: conversation, text: "Q")
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: []) }, stores: stores)
        viewModel.loadConversation(id: conversation.id)

        viewModel.conversationWasDeleted(id: conversation.id)

        #expect(viewModel.consumePendingFocusRequest() == false)
    }

    // MARK: - Nouvelle question du système pendant une réponse

    @Test("Nouvelle question du système pendant une réponse : elle finit en arrière-plan, dans SA conversation")
    func systemNewQuestionLetsTheAnswerFinish() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingQuestionA(viewModel, aiProvider) else { return }

        viewModel.startNewConversationFromSystem()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.currentConversationID == nil)
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundConversationIDs == [idA])
        #expect(viewModel.consumePendingFocusRequest() == true)

        continuation.yield("Début A et la fin de A.")
        continuation.finish()
        await waitUntil("réponse de A enregistrée") { (try? self.answerTexts(stores, idA)) == ["Début A et la fin de A."] }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchanges.isEmpty }

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.errorDescription == nil)
    }

    @Test("Le bouton et ⇧⌘O suivent le même chemin : « Nouvelle conversation » laisse la réponse finir en arrière-plan")
    func userNewConversationLetsTheAnswerFinish() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuation) = await startGeneratingQuestionA(viewModel, aiProvider) else { return }

        viewModel.startNewConversationFromUser()

        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundConversationIDs == [idA])
        #expect(viewModel.consumePendingFocusRequest() == true)

        continuation.yield("Début A et la fin de A.")
        continuation.finish()
        await waitUntil("réponse de A enregistrée") { (try? self.answerTexts(stores, idA)) == ["Début A et la fin de A."] }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchanges.isEmpty }
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.errorDescription == nil)
    }

    @Test("Sans historique pour la recevoir, la réponse en cours ne peut pas continuer : elle est arrêtée proprement")
    func systemNewQuestionWithoutHistoryStopsTheAnswer() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })
        viewModel.startSend(query: "Question A")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Début A")
        await waitUntil("1er snapshot") { viewModel.messages.last?.text == "Début A" }

        viewModel.startNewConversationFromSystem()

        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundExchanges.isEmpty)
    }

    // MARK: - Fichiers joints

    @Test("Fil vide : une nouvelle conversation retire aussi les fichiers joints pas encore envoyés")
    func newConversationOnEmptyThreadRemovesUnsentFiles() async throws {
        let store = AttachmentStore(scorer: ConstantSimilarityScorer(), preparer: StubAttachmentPreparer())
        try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/rapport.txt"))
        let viewModel = makeViewModel(
            resolveProvider: { MockStreamingAIGenerating(chunks: []) },
            attachmentController: FileAttachmentController(store: store)
        )
        #expect(viewModel.messages.isEmpty)

        viewModel.startNewConversationFromSystem()

        #expect(viewModel.attachmentController.attachments.isEmpty)
        #expect(viewModel.consumePendingFocusRequest() == true)
    }

    @Test("Fil commencé : le fichier envoyé ET celui joint après (pas encore envoyé) sont retirés, quel que soit le chemin")
    func newConversationOnStartedThreadRemovesSentAndUnsentFiles() async throws {
        for useSystemPath in [false, true] {
            let store = AttachmentStore(scorer: ConstantSimilarityScorer(), preparer: StubAttachmentPreparer())
            try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/envoye.txt"))
            let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
            let viewModel = makeViewModel(
                resolveProvider: { aiProvider },
                attachmentController: FileAttachmentController(store: store)
            )
            await viewModel.send(query: "Que dit le rapport ?")
            try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/pas-encore-envoye.txt"))
            #expect(viewModel.attachmentController.attachments.count == 2)

            if useSystemPath { viewModel.startNewConversationFromSystem() } else { viewModel.startNewConversationFromUser() }

            #expect(viewModel.messages.isEmpty)
            #expect(viewModel.attachmentController.attachments.isEmpty)
        }
    }

    @Test("Un fichier qui arrive APRÈS la remise à zéro (partage, glisser-déposer) est traité normalement")
    func fileArrivingAfterTheResetIsAttachedNormally() async throws {
        let store = AttachmentStore(scorer: ConstantSimilarityScorer(), preparer: StubAttachmentPreparer())
        try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/ancien.txt"))
        let viewModel = makeViewModel(
            resolveProvider: { MockStreamingAIGenerating(chunks: []) },
            attachmentController: FileAttachmentController(store: store)
        )

        viewModel.startNewConversationFromSystem()
        try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/nouveau.txt"))

        #expect(viewModel.attachmentController.attachments.map(\.fileName) == ["nouveau.txt"])
    }

    @Test("Réponse en cours avec un fichier joint : la remise à zéro retire le fichier, la réponse en arrière-plan finit quand même")
    func answerInFlightFinishesAfterItsFilesAreRemoved() async throws {
        let stores = try PersistenceStores()
        let store = AttachmentStore(scorer: ConstantSimilarityScorer(), preparer: StubAttachmentPreparer())
        try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/rapport.txt"))
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            stores: stores,
            attachmentController: FileAttachmentController(store: store)
        )
        guard let (idA, continuation) = await startGeneratingQuestionA(viewModel, aiProvider) else { return }

        viewModel.startNewConversationFromUser()

        #expect(viewModel.attachmentController.attachments.isEmpty)
        continuation.yield("Début A et la fin de A.")
        continuation.finish()
        await waitUntil("réponse de A enregistrée") { (try? self.answerTexts(stores, idA)) == ["Début A et la fin de A."] }
        #expect(viewModel.errorDescription == nil)
    }
}
