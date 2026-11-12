//
//  SearchOrchestratorStreamingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("SearchOrchestrator.streamAnswer")
struct SearchOrchestratorStreamingTests {
    static func makeResult(title: String, url: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title,
            url: url,
            content: content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    static let instance = URL(string: "https://searxng.example")!

    @Test("Cas nominal : les sources sont renvoyées immédiatement, le flux produit les morceaux du provider dans l'ordre")
    func happyPathReturnsSourcesAndStreamsChunks() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = StreamingMockAIGenerating(chunks: ["Voici ", "la ", "réponse."])
        let orchestrator = makeStreamingOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "quelle est la question ?")

        #expect(streamingAnswer.sources == results)

        var received: [String] = []
        for try await chunk in streamingAnswer.textStream {
            received.append(chunk)
        }
        #expect(received == ["Voici ", "la ", "réponse."])

        // Un seul appel à `streamGenerate` : la génération finale, jamais la
        // classification ni le planner (qui passent par `generate`).
        let streamPrompts = aiProvider.receivedStreamPrompts
        #expect(streamPrompts.count == 1)
        let prompt = try #require(streamPrompts.first)
        #expect(prompt.contains("quelle est la question ?"))
        #expect(prompt.contains("Titre A"))
        #expect(prompt.contains("Titre B"))
    }

    @Test("La limite maxResultsUsedForContext restreint les sources renvoyées, comme answer(query:)")
    func maxResultsLimitsReturnedSources() async throws {
        let results = (1...7).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = StreamingMockAIGenerating()
        let orchestrator = makeStreamingOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(streamingAnswer.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3", "Titre 4", "Titre 5"])
    }

    @Test("Une erreur de recherche remonte AVANT que le flux final soit sollicité : streamAnswer() lève, streamGenerate() n'est jamais appelé (seule la classification, via generate(), a eu lieu)")
    func searchErrorPropagatesBeforeCallingAIProvider() async {
        let client = StreamingMockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = StreamingMockAIGenerating()
        let orchestrator = makeStreamingOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await orchestrator.streamAnswer(query: "requête")
        }

        let generatePrompts = aiProvider.receivedGeneratePrompts
        let streamPrompts = aiProvider.receivedStreamPrompts
        #expect(generatePrompts.count == 1)
        #expect(streamPrompts.isEmpty)
    }

    @Test("Une erreur survenant DANS le stream du provider IA (après des yields) est propagée par le flux, pas par streamAnswer() elle-même")
    func errorInsideProviderStreamPropagatesThroughTextStream() async throws {
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = StreamingMockAIGenerating(chunks: ["premier morceau"], midStreamFailure: StreamingMockError.midStreamFailure)
        let orchestrator = makeStreamingOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        // streamAnswer() elle-même ne lève pas : la recherche a réussi, seul le
        // flux de texte (consommé séparément ci-dessous) porte l'échec.
        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        var received: [String] = []
        await #expect(throws: StreamingMockError.midStreamFailure) {
            for try await chunk in streamingAnswer.textStream {
                received.append(chunk)
            }
        }
        #expect(received == ["premier morceau"])
    }

    // MARK: - Mode de réponse (1.13) : il traverse tout le pipeline

    static let neverDonePlanner = """
    {"action":"scrapeURL","urls":["https://1.example"],"reasoning":"encore"}
    """

    static func sevenResults() -> [SearXNGSearchResult] {
        (1...7).map { makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
    }

    @Test("Sans mode explicite : mode Rapide (défaut produit) — 3 sources, aucun tour planner, 2 appels LLM, consignes Rapide")
    func defaultModeIsQuick() async throws {
        // Le défaut de l'init est écrit en littéral (`.quick`) : ce test
        // échoue si le défaut produit change sans que l'orchestrateur suive.
        #expect(ResponseModeSettingsStore.defaultMode == .quick)
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: StreamingMockScrapeService(),
            sourceRanker: SourceRanker(
                relevanceScorer: StreamingConstantSimilarityScorer(),
                duplicateScorer: StreamingNeverDuplicateScorer(),
                languageIdentifier: StreamingUnknownLanguageIdentifier()
            )
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3"])
        // 1 classification + 0 planner (+ la génération finale, en streaming).
        #expect(aiProvider.receivedGeneratePrompts.count == 1)
        #expect(aiProvider.plannerPromptCount == 0)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("mode Rapide"))
        #expect(!finalPrompt.contains("[4] Titre 4"))
    }

    @Test("Mode Approfondi : 5 sources, jusqu'à 2 tours planner (4 appels LLM), consignes Approfondi")
    func deepModeAllowsTwoPlannerRounds() async throws {
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .deep
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(aiProvider.plannerPromptCount == 2)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("mode Approfondi"))
    }

    @Test("Mode Fiable : seules les sources de domaines fiables atteignent le planner, le prompt et l'interface ; 1 seul tour planner")
    func reliableModeKeepsTrustedDomainsOnly() async throws {
        let results = [
            Self.makeResult(title: "Wiki", url: "https://fr.wikipedia.org/wiki/Photosynthese", content: "Contenu wiki"),
            Self.makeResult(title: "Pin", url: "https://www.pinterest.com/pin/123", content: "Contenu pin"),
            Self.makeResult(title: "Blog", url: "https://blog.example.com/article", content: "Contenu blog"),
            Self.makeResult(title: "Nasa", url: "https://www.nasa.gov/photosynthesis", content: "Contenu nasa"),
        ]
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let scrapeLog = ScrapeLog()
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .reliable,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "photosynthèse")

        #expect(streamingAnswer.sources.map(\.title) == ["Wiki", "Nasa"])
        #expect(aiProvider.plannerPromptCount == 1)
        // Le planner demande https://1.example, absent des sources affichées
        // (bug 8) : avant, cette page non fiable était téléchargée et injectée.
        #expect(await scrapeLog.urls.isEmpty)
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(!plannerPrompt.contains("pinterest.com"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("mode Fiable"))
        #expect(!finalPrompt.contains("pinterest.com"))
        #expect(!finalPrompt.contains("blog.example.com"))
    }

    @Test("Mode Fiable sans aucun domaine fiable : aucune source (jamais de repli non fiable) et AUCUNE génération lancée")
    func reliableModeWithoutTrustedDomainReturnsNoSource() async throws {
        let results = [
            Self.makeResult(title: "Pin", url: "https://www.pinterest.com/pin/123", content: "Contenu pin"),
            Self.makeResult(title: "Quora", url: "https://www.quora.com/question", content: "Contenu quora"),
        ]
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = StreamingMockAIGenerating()
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .reliable
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "question")

        #expect(streamingAnswer.sources.isEmpty)
        #expect(streamingAnswer.artifacts.searchPerformed)
        // Décision (c) : pas de requête au moteur lancée puis annulée.
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        var chunks: [String] = []
        for try await chunk in streamingAnswer.textStream { chunks.append(chunk) }
        #expect(chunks.isEmpty)
        // Même règle sur le chemin non streamé.
        let result = try await orchestrator.answer(query: "question")
        #expect(result.answer.isEmpty)
        #expect(!aiProvider.receivedGeneratePrompts.contains { $0.contains("Question de l'utilisateur") })
    }

    @Test("Les plafonds de l'appelant bornent le mode sans jamais l'élargir")
    func callerCapsNarrowButNeverWidenTheMode() async throws {
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])

        // Plafond large en mode Rapide : le mode (3 sources) l'emporte.
        let quickAI = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let quick = makeStreamingOrchestrator(failoverManager: failoverManager, aiProvider: quickAI, responseMode: .quick, maxResultsUsedForContext: 10)
        #expect(try await quick.streamAnswer(query: "q").sources.count == 3)
        #expect(quickAI.plannerPromptCount == 0)

        // Plafonds serrés en mode Approfondi : 2 sources, aucun tour planner.
        let deepAI = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let deep = makeStreamingOrchestrator(failoverManager: failoverManager, aiProvider: deepAI, responseMode: .deep, maxResultsUsedForContext: 2, maxIterations: 1)
        #expect(try await deep.streamAnswer(query: "q").sources.count == 2)
        #expect(deepAI.plannerPromptCount == 0)
    }
}
