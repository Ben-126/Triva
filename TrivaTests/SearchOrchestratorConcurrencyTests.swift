//
//  SearchOrchestratorConcurrencyTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Borne d'un tour de scrape, `@concurrent` et budgets par moteur de `SearchOrchestratorStreamingTests`.

extension SearchOrchestratorStreamingTests {
    // MARK: - Borne d'un tour de scrape, @concurrent, budgets par moteur

    @Test("Borne d'un tour de scrape : à l'échéance, la page finie est gardée ; la lente est annulée, annoncée en échec au planner et jamais injectée")
    func scrapeRoundDeadlineKeepsFinishedPages() async throws {
        let cancellations = ScrapeLog()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://1.example","https://2.example"]}"#
        let aiProvider = StreamingMockAIGenerating(plannerResponse: planner)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: SlowScrapeService(slowURLs: ["https://2.example"], cancellations: cancellations),
            scrapeRoundTimeout: .milliseconds(200)
        )

        let start = ContinuousClock.now
        _ = try await orchestrator.streamAnswer(query: "requête")

        // Sans échéance : 30 s d'attente sur la page lente, puis son contenu injecté.
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(await cancellations.urls == ["https://2.example"])
        let lastPlannerPrompt = try #require(aiProvider.receivedGeneratePrompts.last { $0.contains("<planner_context>") })
        #expect(lastPlannerPrompt.contains("https://1.example (page déjà récupérée)"))
        #expect(lastPlannerPrompt.contains("https://2.example (récupération échouée, ne la redemande pas)"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Contenu scrapé pour https://1.example"))
        #expect(!finalPrompt.contains("Contenu tardif"))
    }

    /// SANS `@concurrent`, `answer`/`streamAnswer` (méthodes `nonisolated
    /// async`) tourneraient sur l'acteur de l'appelant — le main actor ici,
    /// comme pour `ChatViewModel` — et la sonde y serait lue.
    @Test("@concurrent : appelés depuis le main actor, answer et streamAnswer exécutent le pipeline hors du thread principal")
    func pipelineRunsOffTheMainThread() async throws {
        #expect(streamingIsRunningOnMainThread(), "prémisse : l'appelant est bien sur le thread principal")
        let journal = ThreadJournal()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner),
            clock: ThreadProbeClock(journal: journal)
        )

        _ = try await orchestrator.streamAnswer(query: "requête")
        _ = try await orchestrator.answer(query: "requête")

        #expect(journal.mainThreadReadings == [false, false])
    }

    @Test("Bug 6 : préréglage Apple Intelligence — classifieur et rédaction en version courte, historique borné dans LES DEUX prompts, 2 pages par tour")
    func appleIntelligencePresetDrivesEveryPrompt() async throws {
        let scrapeLog = ScrapeLog()
        let longAnswer = String(repeating: "La photosynthèse produit du glucose. ", count: 100)
        let history = (1...3).flatMap { turn in
            [ClassifierChatMessage(role: .user, content: "Question \(turn)"), ClassifierChatMessage(role: .assistant, content: longAnswer)]
        }
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://1.example","https://2.example","https://3.example"]}"#
        let aiProvider = StreamingMockAIGenerating(plannerResponse: planner)
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .deep,
            configuration: .appleIntelligence,
            scrapeService: RecordingScrapeService(log: scrapeLog),
            sourceRanker: streamingOrderPreservingRanker(),
            maxIterations: 2
        )

        _ = try await orchestrator.streamAnswer(query: "Et le rendement ?", chatHistory: history)

        // Classifieur : prompt court, 4 derniers messages, chacun coupé à 600 caractères.
        let budget = SearchPipelineConfiguration.appleIntelligence
        let classifierPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<user_query>") })
        let expectedClassifierPrompt = QueryClassifier.buildPrompt(
            query: "Et le rendement ?",
            chatHistory: SearchOrchestrator.boundedHistory(history, maxMessages: 4, maxCharacters: 600),
            maxHistoryMessages: 4,
            promptComplexity: .concise
        )
        #expect(classifierPrompt == expectedClassifierPrompt)
        #expect(!classifierPrompt.contains("Question 1"))
        #expect(classifierPrompt.contains("[…]"))

        // Planner et scraping : 2 pages par tour, annoncées et exécutées.
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(plannerPrompt.contains("au plus \(budget.maxScrapedURLsPerIteration) à la fois"))
        #expect(Set(await scrapeLog.urls) == ["https://1.example", "https://2.example"])

        // Rédaction : prompt court, historique borné de la même façon.
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.hasPrefix("Tu es Triva. Réponds"))
        #expect(!finalPrompt.contains("Question 1"))
        #expect(finalPrompt.contains("Utilisateur : Question 2"))
        #expect(finalPrompt.components(separatedBy: "produit du glucose").count - 1 <= 2 * (600 / 37))
    }
}
