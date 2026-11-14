//
//  ChatViewModelOwnedGenerationTests.swift
//  TrivaTests
//
//  Mission C3 (revue R3-1, R3-6) : la génération appartient au modèle, pas à la vue.
//

import Testing
import Foundation
@testable import Triva

/// Compteur partagé entre un test et la closure qu'il injecte.
@MainActor
private final class ResolutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

extension ChatViewModelTests {
    // MARK: - La génération survit à la vue (R3-1)

    @Test("startSend porte l'échange jusqu'au bout sans aucune Task de la vue : la réponse arrive complète")
    func startSendRunsTheExchangeWithoutAViewOwnedTask() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        viewModel.startSend(query: "requête")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Voici un début")
        await waitUntil("1er snapshot reflété") { viewModel.messages.last?.text == "Voici un début" }
        // Ici l'ancienne `ChatView` aurait été démontée (iPhone Duo ouvert, Split View) : rien ne doit couper.
        #expect(viewModel.isGenerating)
        continuation.yield("Voici un début et la fin.")
        continuation.finish()
        await waitUntil("échange terminé") { !viewModel.isGenerating }

        #expect(viewModel.messages.last?.text == "Voici un début et la fin.")
        #expect(viewModel.messages.last?.status == .completed)
        #expect(viewModel.errorDescription == nil)
    }

    @Test("stop() arrête l'échange lancé par startSend : texte gardé, réponse interrompue, aucune erreur")
    func stopCancelsTheExchangeStartedByStartSend() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        viewModel.startSend(query: "requête")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Voici un début")
        await waitUntil("1er snapshot reflété") { viewModel.messages.last?.text == "Voici un début" }

        viewModel.stop()
        await waitUntil("échange arrêté") { !viewModel.isGenerating }

        #expect(viewModel.messages.last?.text == "Voici un début")
        #expect(viewModel.messages.last?.status == .interrupted)
        #expect(viewModel.errorDescription == nil)
    }

    @Test("« Nouvelle conversation » arrête encore l'échange lancé par startSend")
    func newConversationStillCancelsTheStartedExchange() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        viewModel.startSend(query: "requête")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Début")
        await waitUntil("1er snapshot reflété") { viewModel.messages.last?.text == "Début" }

        viewModel.startNewConversation()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isGenerating == false)
    }

    @Test("Une suggestion touchée pendant une génération est ignorée")
    func startSuggestionIsIgnoredWhileGenerating() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        viewModel.startSend(query: "première")
        guard await waitForContinuation(aiProvider) != nil else { return }
        viewModel.startSuggestion("seconde")

        #expect(viewModel.messages.filter { $0.role == .user }.map(\.text) == ["première"])
        viewModel.stop()
        await waitUntil("échange arrêté") { !viewModel.isGenerating }
    }

    // MARK: - Étape affichée hors connexion (R3-6)

    @Test("Hors connexion avec un modèle local : « Rédaction… » dès le départ, jamais « Recherche des sources… » ; en ligne, « Réflexion… » tant que rien n'est cherché")
    func offlineLocalModelNeverAnnouncesASearch() async {
        let cases: [(plan: OfflinePlan?, expected: GenerationStage)] = [
            (.answerWithoutSearch, .writing),
            (nil, .analyzing),
        ]
        for testCase in cases {
            let resolutions = ResolutionCounter()
            let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
            let viewModel = ChatViewModel(
                resolveProvider: {
                    resolutions.increment()
                    // Chargement de modèle qui dure : l'étape se lit pendant cette attente.
                    try await Task.sleep(for: .seconds(60))
                    return MockStreamingAIGenerating()
                },
                resolveFailoverManager: { failoverManager },
                resolveOfflinePlan: { testCase.plan },
                makeOrchestrator: { Self.deterministicOrchestrator($0) }
            )

            viewModel.startSend(query: "requête")
            await waitUntil("le provider est en cours de résolution") { resolutions.count == 1 }

            #expect(viewModel.messages.last?.generationStage == testCase.expected)
            viewModel.stop()
            await waitUntil("échange arrêté") { !viewModel.isGenerating }
        }
    }
}
