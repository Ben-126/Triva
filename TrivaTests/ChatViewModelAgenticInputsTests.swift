//
//  ChatViewModelAgenticInputsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Tâche 2.4 : l'enquêteur résolu par la session arrive jusqu'à l'orchestrateur de l'envoi.
extension ChatViewModelTests {
    @Test("L'enquêteur est relu à chaque envoi et transmis à l'orchestrateur ; nil par défaut")
    func agenticResearcherReachesOrchestrator() async throws {
        let researcher = StubAgenticResearcher(.finishImmediately)
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        var resolutions = 0
        var received: [Bool] = []
        let viewModel = ChatViewModel(
            resolveProvider: { MockStreamingAIGenerating(chunks: ["réponse"]) },
            resolveFailoverManager: { failoverManager },
            resolveAgenticResearcher: {
                resolutions += 1
                return researcher
            },
            makeOrchestrator: { inputs in
                received.append(inputs.agenticResearcher is StubAgenticResearcher)
                return Self.deterministicOrchestrator(inputs)
            },
            generateSuggestions: { _, _ in [] }
        )

        await viewModel.send(query: "première")
        await viewModel.send(query: "seconde")

        #expect(resolutions == 2)
        #expect(received == [true, true])
        #expect(ChatViewModel.OrchestratorInputs(
            failoverManager: failoverManager,
            provider: MockStreamingAIGenerating(chunks: []),
            responseMode: .quick,
            configuration: .appleIntelligence,
            webSearchChain: nil
        ).agenticResearcher == nil)
    }
}
