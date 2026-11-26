//
//  ChatViewModelAutoResumeTests.swift
//  TrivaTests
//
//  F3 (26/11) : sur iPhone et iPad, une réponse du modèle local coupée parce que l'app est passée en arrière-plan
//  (« Réponse interrompue » + « Réessayer ») REPREND TOUTE SEULE au retour au premier plan, par le chemin de « Réessayer »,
//  UNE fois par réponse, jamais après un Stop volontaire, une erreur ou un autre départ (nouvelle question).
//

import Foundation
import Testing
@testable import Triva

extension ChatViewModelTests {
    /// Question en cours, début affiché ; rend le flux ouvert.
    private func generatingQuestion(
        _ viewModel: ChatViewModel,
        _ aiProvider: ControllableStreamingAIGenerating
    ) async -> AsyncThrowingStream<String, Error>.Continuation? {
        viewModel.startSend(query: "Question longue")
        guard let continuation = await waitForContinuation(aiProvider) else { return nil }
        continuation.yield("Le début")
        await waitUntil("début affiché") { viewModel.messages.last?.text == "Le début" }
        return continuation
    }

    // MARK: - La reprise

    @Test("Coupée par l'arrière-plan, la réponse reprend toute seule au retour : même question, même bulle, écrite UNE fois")
    func backgroundCutAnswerResumesOnReturn() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }
        let answerID = try #require(viewModel.messages.last?.id)

        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        #expect(viewModel.messages.last?.status == .interrupted)
        #expect(aiProvider.receivedPrompts.count == 1, "rien ne repart pendant l'arrière-plan")

        viewModel.resumeAfterBackgroundInterruption()
        await waitUntil("second flux ouvert") { aiProvider.receivedPrompts.count == 2 }
        aiProvider.continuation?.yield("La réponse entière")
        aiProvider.continuation?.finish()
        await waitUntil("réponse refaite") { viewModel.messages.last?.status == .completed && !viewModel.isGenerating }

        #expect(viewModel.messages.map(\.text) == ["Question longue", "La réponse entière"])
        #expect(viewModel.messages.last?.id == answerID)
        let saved = try #require(try stores.onlyConversation()).orderedMessages
        #expect(saved.map(\.text) == ["Question longue", "La réponse entière"])
        #expect(aiProvider.receivedPrompts.last?.contains("Question longue") == true)
    }

    @Test("UNE seule reprise automatique par réponse : une seconde coupure laisse « Réessayer » au bouton")
    func onlyOneAutomaticResumePerAnswer() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: try PersistenceStores())
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }
        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        await waitUntil("second flux ouvert") { aiProvider.receivedPrompts.count == 2 }
        aiProvider.continuation?.yield("Début de la reprise")
        await waitUntil("reprise affichée") { viewModel.messages.last?.text == "Début de la reprise" }

        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(aiProvider.receivedPrompts.count == 2, "pas de troisième envoi tout seul")
        let last = try #require(viewModel.messages.last)
        #expect(last.status == .interrupted)
        #expect(viewModel.canRetryInterrupted(last), "le bouton « Réessayer » reste là")
    }

    // MARK: - Ce qui ne reprend jamais

    @Test("Stop volontaire juste avant l'arrière-plan : jamais de reprise automatique")
    func voluntaryStopNeverResumes() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: try PersistenceStores())
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }

        viewModel.stop()  // l'utilisateur a touché Stop ; l'échange se termine encore
        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(aiProvider.receivedPrompts.count == 1)
        #expect(viewModel.messages.last?.status == .interrupted)
    }

    @Test("Stop volontaire bien avant, puis arrière-plan : rien à reprendre")
    func earlierVoluntaryStopNeverResumes() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: try PersistenceStores())
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }
        await viewModel.stopAndWait()

        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(aiProvider.receivedPrompts.count == 1)
    }

    @Test("Réponse finie en erreur : jamais de reprise automatique")
    func failedAnswerNeverResumes() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: try PersistenceStores())
        guard let continuation = await generatingQuestion(viewModel, aiProvider) else { return }
        struct Boom: Error {}
        continuation.finish(throwing: Boom())
        await waitUntil("échec constaté") { viewModel.messages.last?.status == .failed && !viewModel.isGenerating }

        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(aiProvider.receivedPrompts.count == 1)
        #expect(viewModel.messages.last?.status == .failed)
    }

    @Test("Session sans fenêtre (Siri, Raccourcis) : jamais de reprise, elle génèrerait pour personne")
    func headlessSessionNeverResumes() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: try PersistenceStores())
        viewModel.resumesAfterBackgroundInterruption = false
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }

        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(aiProvider.receivedPrompts.count == 1)
        #expect(viewModel.messages.last?.status == .interrupted)
    }

    @Test("Accord IA cloud manquant : rien ne part tout seul")
    func missingCloudConsentBlocksTheResume() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let consentNeeded = ConsentSwitch()
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager },
            makeOrchestrator: { inputs in Self.deterministicOrchestrator(inputs) },
            generateSuggestions: { _, _ in [] },
            makeMediaSearcher: { _ in RecordingMediaSearcher() },
            resolveConsentRequest: { consentNeeded.isNeeded ? CloudAIConsentRequest(providerID: "openai", displayName: "Test", host: nil, privacyURL: nil, termsURL: nil, extras: []) : nil }
        )
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }
        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        consentNeeded.isNeeded = true  // l'accord a été retiré entre-temps

        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(aiProvider.receivedPrompts.count == 1)
        #expect(viewModel.pendingConsent == nil, "pas de feuille surgie toute seule au retour")
    }

    // MARK: - Interaction avec « nouvelle question » (widget, Siri, bouton Action)

    @Test("Nouvelle question du système AVANT la reprise : le fil est neuf, rien n'est repris dedans")
    func newQuestionBeforeTheResumeWins() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: try PersistenceStores())
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }
        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))

        viewModel.startNewConversationFromSystem()
        viewModel.resumeAfterBackgroundInterruption()
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.messages.isEmpty)
        #expect(!viewModel.isGenerating)
        #expect(aiProvider.receivedPrompts.count == 1)
    }

    @Test("Nouvelle question du système APRÈS la reprise : la réponse reprise finit en arrière-plan et est enregistrée")
    func newQuestionAfterTheResumeLetsItFinish() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        guard await generatingQuestion(viewModel, aiProvider) != nil else { return }
        let conversationID = try #require(viewModel.currentConversationID)
        await viewModel.stopBecauseAppLeftForeground(timeout: .seconds(3))
        viewModel.resumeAfterBackgroundInterruption()
        await waitUntil("second flux ouvert") { aiProvider.receivedPrompts.count == 2 }

        viewModel.startNewConversationFromSystem()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.backgroundConversationIDs == [conversationID])
        aiProvider.continuation?.yield("La réponse entière")
        aiProvider.continuation?.finish()
        await waitUntil("arrière-plan soldé") { viewModel.backgroundExchanges.isEmpty }

        let saved = try #require(try stores.history.conversation(with: conversationID)).orderedMessages
        #expect(saved.map(\.text) == ["Question longue", "La réponse entière"])
    }
}

/// Interrupteur de consentement pour le test d'accord manquant.
@MainActor
private final class ConsentSwitch {
    var isNeeded = false
}
