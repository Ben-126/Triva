//
//  ChatViewModelStopAndWaitTests.swift
//  TrivaTests
//
//  Mission C6 : « Tout effacer » arrête la génération en cours ET attend sa fin avant d'effacer.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
    @Test("stopAndWait arrête la génération en cours et ne rend la main qu'une fois l'échange terminé")
    func stopAndWaitEndsTheExchange() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        viewModel.startSend(query: "requête")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Début de réponse")
        await waitUntil("1er snapshot reflété") { viewModel.messages.last?.text == "Début de réponse" }

        await viewModel.stopAndWait()

        // Pas d'attente supplémentaire : à son retour, plus rien ne tourne.
        #expect(!viewModel.isGenerating)
        #expect(viewModel.messages.last?.status == .interrupted)
    }

    @Test("stopAndWait sans génération rend la main tout de suite")
    func stopAndWaitWithoutGenerationReturns() async {
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating() })
        await viewModel.stopAndWait()
        #expect(!viewModel.isGenerating)
    }
}
