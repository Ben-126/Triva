//
//  ChatViewModelInterruptedTests.swift
//  TrivaTests
//
//  Mission M (25/11) : une question restée sans réponse (plantage, app fermée) se voit et se relance, sans que rien ne
//  parte tout seul.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Mission M — conversations dont une réponse est en cours")
struct ActiveExchangeRegistryTests {
    @Test("Compté par conversation ; deux réponses en cours, la première finie n'efface pas la seconde")
    func counts() {
        let registry = ActiveExchangeRegistry()
        let (a, b) = (UUID(), UUID())
        registry.begin(a)
        registry.begin(a)
        #expect(registry.isAnswering(a))
        #expect(!registry.isAnswering(b))
        registry.end(a)
        #expect(registry.isAnswering(a))
        registry.end(a)
        #expect(!registry.isAnswering(a))
    }

    @Test("Sans conversation, ou fin sans début : sans effet")
    func nilAndUnbalanced() {
        let registry = ActiveExchangeRegistry()
        registry.begin(nil)
        registry.end(UUID())
        #expect(!registry.isAnswering(nil))
    }
}

@MainActor
@Suite("Mission M — questions sans réponse d'un fil relu")
struct UnansweredQuestionsTests {
    typealias Message = ChatViewModel.Message

    private func answer(_ text: String) -> Message {
        var message = Message(role: .assistant, isStreaming: true)
        message.apply(snapshot: text, at: .now)
        message.finish(.completed, at: .now)
        return message
    }

    private func marked(_ thread: [Message], coming: Bool = false) -> [Message] {
        ChatViewModel.markingUnansweredQuestions(thread, isAnswerComing: coming, at: .now)
    }

    @Test("Fil vide, fil complet : inchangés")
    func completeThreadsAreUntouched() {
        #expect(marked([]).isEmpty)
        let thread = [Message(role: .user, text: "Q1"), answer("R1"), Message(role: .user, text: "Q2"), answer("R2")]
        #expect(marked(thread).map(\.id) == thread.map(\.id))
    }

    @Test("Dernière question sans réponse : une réponse interrompue, vide, la suit")
    func lastUnanswered() throws {
        let thread = [Message(role: .user, text: "Q1"), answer("R1"), Message(role: .user, text: "Q2")]
        let result = marked(thread)
        #expect(result.map(\.role) == [.user, .assistant, .user, .assistant])
        let last = try #require(result.last)
        #expect(last.status == .interrupted)
        #expect(last.text.isEmpty)
        #expect(!last.isStreaming)
        #expect(last.storedMessageID == nil)
    }

    @Test("Question sans réponse au milieu : marquée aussi, l'ordre est gardé")
    func middleUnanswered() {
        let result = marked([Message(role: .user, text: "Q1"), Message(role: .user, text: "Q2"), answer("R2")])
        #expect(result.map(\.text) == ["Q1", "", "Q2", "R2"])
        #expect(result[1].status == .interrupted)
    }

    @Test("Réponse en cours ailleurs (autre fenêtre, Siri) : la dernière question n'est pas marquée, les autres si")
    func answerIsComing() {
        let result = marked([Message(role: .user, text: "Q1"), Message(role: .user, text: "Q2")], coming: true)
        #expect(result.map(\.text) == ["Q1", "", "Q2"])
    }
}

extension ChatViewModelTests {
    /// Une conversation telle qu'un plantage la laisse : la question, rien d'autre.
    private func unansweredConversation(_ stores: PersistenceStores) throws -> StoredConversation {
        let conversation = try stores.history.createConversation(firstQuestion: "Question coupée")
        try stores.history.appendUserMessage(to: conversation, text: "Question coupée")
        return conversation
    }

    @Test("Au relancement : « Réponse interrompue » et « Réessayer », rien d'envoyé, rien d'écrit (mission M)")
    func reopenedUnansweredQuestionIsMarkedAndNothingIsSent() async throws {
        let stores = try PersistenceStores()
        let conversation = try unansweredConversation(stores)
        let aiProvider = MockStreamingAIGenerating(chunks: ["Ne doit pas partir."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        let revision = stores.history.revision

        #expect(viewModel.loadConversation(id: conversation.id))
        try await Task.sleep(for: .milliseconds(50))

        let last = try #require(viewModel.messages.last)
        #expect(last.status == .interrupted)
        #expect(viewModel.canRetryInterrupted(last))
        #expect(!viewModel.canRetryInQuickMode(last))
        #expect(!viewModel.isGenerating)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        #expect(stores.history.revision == revision)
    }

    @Test("« Réessayer » : même question, réponse écrite UNE fois, question jamais en double (mission M)")
    func retryAnswersTheStoredQuestion() async throws {
        let stores = try PersistenceStores()
        let conversation = try unansweredConversation(stores)
        let aiProvider = MockStreamingAIGenerating(chunks: ["La réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        viewModel.loadConversation(id: conversation.id)
        let interruptedID = try #require(viewModel.messages.last?.id)

        viewModel.start(.retryInterrupted(messageID: interruptedID))
        await waitUntil("réponse refaite") { viewModel.messages.last?.status == .completed && !viewModel.isGenerating }

        #expect(viewModel.messages.map(\.text) == ["Question coupée", "La réponse."])
        #expect(viewModel.messages.last?.id == interruptedID)
        let saved = try #require(try stores.history.conversation(with: conversation.id)).orderedMessages
        #expect(saved.map(\.text) == ["Question coupée", "La réponse."])
        #expect(aiProvider.receivedStreamPrompts.last?.contains("Question coupée") == true)
    }

    @Test("Arrêt en cours de réponse : début gardé, marqué, relançable dans la session (mission M)")
    func stoppedAnswerCanBeRetried() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        viewModel.startSend(query: "Question longue")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Le début")
        await waitUntil("début affiché") { viewModel.messages.last?.text == "Le début" }
        #expect(!viewModel.canRetryInterrupted(viewModel.messages[1]))

        await viewModel.stopAndWait()

        let last = try #require(viewModel.messages.last)
        #expect(last.status == .interrupted)
        #expect(last.text == "Le début")
        #expect(viewModel.canRetryInterrupted(last))
        let saved = try #require(try stores.onlyConversation()).orderedMessages
        #expect(saved.map(\.text) == ["Question longue", "Le début"])
    }

    @Test("« Réessayer » après un début enregistré : la nouvelle réponse REMPLACE le début dans l'historique (mission M)")
    func retryReplacesTheStoredPartial() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        viewModel.startSend(query: "Question longue")
        guard let first = await waitForContinuation(aiProvider) else { return }
        first.yield("Le début")
        await waitUntil("début affiché") { viewModel.messages.last?.text == "Le début" }
        await viewModel.stopAndWait()
        let id = try #require(viewModel.messages.last?.id)

        viewModel.start(.retryInterrupted(messageID: id))
        await waitUntil("second flux ouvert") { aiProvider.receivedPrompts.count == 2 }
        aiProvider.continuation?.yield("La réponse entière")
        aiProvider.continuation?.finish()
        await waitUntil("réponse refaite") { viewModel.messages.last?.status == .completed && !viewModel.isGenerating }

        let saved = try #require(try stores.onlyConversation()).orderedMessages
        #expect(saved.map(\.text) == ["Question longue", "La réponse entière"])
    }

    @Test("Pas la dernière réponse, ou réponse complète : pas de « Réessayer » (mission M)")
    func retryOnlyOnTheLastInterruptedAnswer() async throws {
        let stores = try PersistenceStores()
        let conversation = try unansweredConversation(stores)
        try stores.history.appendUserMessage(to: conversation, text: "Suivante")
        try stores.history.appendAssistantMessage(to: conversation, text: "Réponse suivante.", sources: [])
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: []) }, stores: stores)
        viewModel.loadConversation(id: conversation.id)

        #expect(viewModel.messages.map(\.status.isInterruptedForTest) == [false, true, false, false])
        #expect(viewModel.messages.allSatisfy { !viewModel.canRetryInterrupted($0) })
    }

    @Test("Conversation à laquelle une AUTRE fenêtre est en train de répondre : pas marquée, pas relançable (mission M)")
    func conversationAnsweredElsewhereIsNotMarked() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let windowA = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        windowA.startSend(query: "Question A")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        let id = try #require(windowA.currentConversationID)
        let windowB = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        #expect(windowB.loadConversation(id: id))
        #expect(windowB.messages.map(\.role) == [.user])

        continuation.yield("Réponse A")
        continuation.finish()
        await waitUntil("A finie") { !windowA.isGenerating }
        await waitUntil("registre vidé") { !ActiveExchangeRegistry.shared.isAnswering(id) }
        let windowC = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        #expect(windowC.loadConversation(id: id))
        #expect(windowC.messages.map(\.text) == ["Question A", "Réponse A"])
        #expect(windowC.messages.last?.status == .completed)
    }

    @Test("Un échange interrompu n'entre pas dans l'historique donné au modèle (mission M)")
    func interruptedExchangeIsNotSentToTheModel() async throws {
        let stores = try PersistenceStores()
        let conversation = try unansweredConversation(stores)
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        viewModel.loadConversation(id: conversation.id)

        await viewModel.send(query: "Autre question")

        #expect(viewModel.messages.map(\.text) == ["Question coupée", "", "Autre question", "Réponse."])
        #expect(aiProvider.receivedStreamPrompts.last?.contains("Question coupée") == false)
        let saved = try #require(try stores.history.conversation(with: conversation.id)).orderedMessages
        #expect(saved.map(\.text) == ["Question coupée", "Autre question", "Réponse."])
    }
}

private extension ChatViewModel.Message.Status {
    var isInterruptedForTest: Bool { self == .interrupted }
}
