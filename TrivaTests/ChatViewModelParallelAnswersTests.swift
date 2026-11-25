//
//  ChatViewModelParallelAnswersTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission NC, décision de Ben du 25/11) : « Nouvelle conversation » laisse la réponse finir en
//  arrière-plan, et la question suivante n'arrête PAS cette réponse : deux réponses (ou plus) finissent chacune dans
//  leur conversation. Le bouton Stop ne touche qu'au fil affiché ; tout arrêter est réservé à la fin de session.
//

import Testing
import Foundation
@testable import Triva

@MainActor
private final class ProgressRecorder: SearchProgressObserving {
    private(set) var events: [(event: SearchProgressEvent, answerID: UUID)] = []

    func searchProgress(_ event: SearchProgressEvent, answerID: UUID) {
        events.append((event, answerID))
    }

    /// Réponses terminées (`completed`), dans l'ordre.
    var completedAnswerIDs: [UUID] { events.filter { $0.event == .completed }.map(\.answerID) }
    var startedAnswerIDs: [UUID] {
        events.compactMap { if case .started = $0.event { $0.answerID } else { nil } }
    }
}

extension ChatViewModelTests {
    private func storedAnswers(_ stores: PersistenceStores, _ id: UUID) throws -> [String] {
        try stores.history.conversation(with: id)?.orderedMessages.filter { $0.role == .assistant }.map(\.text) ?? []
    }

    /// Question `query` lancée, « Début `tag` » streamé. Rend sa conversation et sa continuation.
    private func startAnswering(
        _ viewModel: ChatViewModel,
        _ aiProvider: ControllableStreamingAIGenerating,
        query: String,
        tag: String,
        promptCount: Int
    ) async -> (UUID, AsyncThrowingStream<String, Error>.Continuation)? {
        viewModel.startSend(query: query)
        await waitUntil("génération \(tag) lancée") { aiProvider.receivedPrompts.count == promptCount }
        guard let continuation = aiProvider.continuation, let conversationID = viewModel.currentConversationID else { return nil }
        continuation.yield("Début \(tag)")
        await waitUntil("1er snapshot de \(tag)") { viewModel.messages.last?.text == "Début \(tag)" }
        return (conversationID, continuation)
    }

    // MARK: - Deux réponses qui finissent

    @Test("Nouvelle conversation puis question suivante : la première réponse n'est pas arrêtée, les deux finissent chacune chez elle")
    func newConversationThenSendLetsBothAnswersFinish() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        let recorder = ProgressRecorder()
        viewModel.progressObserver = recorder
        guard let (idA, continuationA) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }

        viewModel.startNewConversationFromUser()
        guard let (idB, continuationB) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }
        #expect(idA != idB)
        #expect(viewModel.backgroundConversationIDs == [idA])

        // B finit la première, puis A : l'ordre d'arrivée n'a pas d'importance.
        continuationB.yield("Début B et la fin de B.")
        continuationB.finish()
        await waitUntil("B enregistrée") { (try? self.storedAnswers(stores, idB)) == ["Début B et la fin de B."] }
        #expect(viewModel.backgroundConversationIDs == [idA])
        continuationA.yield("Début A et la fin de A.")
        continuationA.finish()
        await waitUntil("A enregistrée") { (try? self.storedAnswers(stores, idA)) == ["Début A et la fin de A."] }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchanges.isEmpty }

        #expect(viewModel.messages.map(\.text) == ["Question B", "Début B et la fin de B."])
        #expect(viewModel.errorDescription == nil)
        // L'activité en direct suit chaque réponse jusqu'au bout : deux débuts, deux fins « prêt », aucune interrompue.
        #expect(recorder.startedAnswerIDs.count == 2)
        #expect(Set(recorder.completedAnswerIDs) == Set(recorder.startedAnswerIDs))
        #expect(!recorder.events.contains { $0.event == .interrupted })
    }

    @Test("Trois réponses en même temps : deux en arrière-plan, une affichée, toutes enregistrées")
    func threeAnswersAtOnce() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuationA) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, continuationB) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }
        viewModel.startNewConversationFromSystem()
        guard let (idC, continuationC) = await startAnswering(viewModel, aiProvider, query: "Question C", tag: "C", promptCount: 3) else { return }
        #expect(viewModel.backgroundConversationIDs == [idA, idB])

        for (continuation, tag) in [(continuationC, "C"), (continuationA, "A"), (continuationB, "B")] {
            continuation.yield("Début \(tag) fini.")
            continuation.finish()
        }
        await waitUntil("trois réponses enregistrées") {
            (try? self.storedAnswers(stores, idA)) == ["Début A fini."]
                && (try? self.storedAnswers(stores, idB)) == ["Début B fini."]
                && (try? self.storedAnswers(stores, idC)) == ["Début C fini."]
        }
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchanges.isEmpty }
        #expect(!viewModel.isGenerating)
    }

    // MARK: - Arrêter

    @Test("Stop arrête la réponse AFFICHÉE seulement : celle laissée en arrière-plan continue")
    func stopOnlyStopsTheDisplayedAnswer() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuationA) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, _) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }

        viewModel.stop()
        await waitUntil("partiel de B enregistré") { (try? self.storedAnswers(stores, idB)) == ["Début B"] }

        #expect(viewModel.backgroundConversationIDs == [idA])
        continuationA.yield("Début A et la fin de A.")
        continuationA.finish()
        await waitUntil("A enregistrée") { (try? self.storedAnswers(stores, idA)) == ["Début A et la fin de A."] }
    }

    @Test("Revenir sur la réponse laissée en arrière-plan : elle s'affiche en direct, Stop ne l'arrête qu'elle, l'autre continue")
    func reopeningTheBackgroundAnswerWhileAnotherGenerates() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuationA) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, continuationB) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }

        // On revient sur A pendant que B écrit : B passe en arrière-plan, elle n'est PAS annulée.
        #expect(viewModel.loadConversation(id: idA))
        #expect(viewModel.currentConversationID == idA)
        #expect(viewModel.isGenerating)
        #expect(viewModel.backgroundConversationIDs == [idB])
        continuationA.yield("Début A, suite.")
        await waitUntil("A vivante à l'écran") { viewModel.messages.last?.text == "Début A, suite." }

        viewModel.stop()
        await waitUntil("partiel de A enregistré") { (try? self.storedAnswers(stores, idA)) == ["Début A, suite."] }
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundConversationIDs == [idB])

        continuationB.yield("Début B et la fin de B.")
        continuationB.finish()
        await waitUntil("B enregistrée") { (try? self.storedAnswers(stores, idB)) == ["Début B et la fin de B."] }
    }

    @Test("Tout arrêter (fenêtre fermée) : la réponse affichée ET celles en arrière-plan s'arrêtent, débuts gardés")
    func stopEverythingStopsAllAnswers() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, _) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, _) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }

        viewModel.stopEverything()

        await waitUntil("débuts gardés") {
            (try? self.storedAnswers(stores, idA)) == ["Début A"] && (try? self.storedAnswers(stores, idB)) == ["Début B"]
        }
        await waitUntil("plus rien en arrière-plan") { viewModel.backgroundExchanges.isEmpty && !viewModel.isGenerating }
    }

    @Test("« Tout effacer » (stopAndWait) attend TOUTES les réponses, y compris celles en arrière-plan")
    func stopAndWaitWaitsForBackgroundAnswersToo() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, _) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, _) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }

        await viewModel.stopAndWait()

        // Dès le retour : les deux débuts sont déjà écrits, rien ne s'écrira après l'effacement.
        #expect(try storedAnswers(stores, idA) == ["Début A"])
        #expect(try storedAnswers(stores, idB) == ["Début B"])
        #expect(viewModel.backgroundExchanges.isEmpty)
    }

    // MARK: - Suppression

    @Test("Conversation affichée supprimée en pleine réponse : elle repart à zéro, l'autre réponse en arrière-plan continue")
    func deletingTheDisplayedAnsweringConversationKeepsTheBackgroundOne() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, continuationA) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, _) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }

        let conversationB = try #require(try stores.history.conversation(with: idB))
        try stores.history.delete(conversationB)
        viewModel.conversationWasDeleted(id: idB)

        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundConversationIDs == [idA])
        continuationA.yield("Début A et la fin de A.")
        continuationA.finish()
        await waitUntil("A enregistrée") { (try? self.storedAnswers(stores, idA)) == ["Début A et la fin de A."] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try stores.history.conversation(with: idB) == nil)
    }

    @Test("Conversation en arrière-plan supprimée : seule sa réponse est arrêtée, rien n'est réécrit")
    func deletingOneBackgroundConversationLeavesTheOthers() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard let (idA, _) = await startAnswering(viewModel, aiProvider, query: "Question A", tag: "A", promptCount: 1) else { return }
        viewModel.startNewConversationFromUser()
        guard let (idB, continuationB) = await startAnswering(viewModel, aiProvider, query: "Question B", tag: "B", promptCount: 2) else { return }
        viewModel.startNewConversationFromUser()
        #expect(viewModel.backgroundConversationIDs == [idA, idB])

        let conversationA = try #require(try stores.history.conversation(with: idA))
        try stores.history.delete(conversationA)
        viewModel.conversationWasDeleted(id: idA)

        #expect(viewModel.backgroundConversationIDs == [idB])
        continuationB.yield("Début B et la fin de B.")
        continuationB.finish()
        await waitUntil("B enregistrée") { (try? self.storedAnswers(stores, idB)) == ["Début B et la fin de B."] }
        #expect(try stores.history.conversation(with: idA) == nil)
    }

    // MARK: - Garde-fous

    @Test("Sans conversation d'historique pour la recevoir, « Nouvelle conversation » arrête la réponse (comme avant)")
    func newConversationWithoutHistoryStillStopsTheAnswer() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })
        viewModel.startSend(query: "Question A")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Début A")
        await waitUntil("1er snapshot") { viewModel.messages.last?.text == "Début A" }

        viewModel.startNewConversationFromUser()

        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isGenerating)
        #expect(viewModel.backgroundExchanges.isEmpty)
    }

    @Test("Réponse seule affichée, rien en arrière-plan : « Nouvelle conversation » ne crée aucune réponse fantôme")
    func newConversationOnIdleThreadCreatesNoBackgroundAnswer() async throws {
        let stores = try PersistenceStores()
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: ["Réponse."]) }, stores: stores)
        await viewModel.send(query: "Question A")

        viewModel.startNewConversationFromUser()

        #expect(viewModel.backgroundExchanges.isEmpty)
        #expect(viewModel.messages.isEmpty)
    }
}
