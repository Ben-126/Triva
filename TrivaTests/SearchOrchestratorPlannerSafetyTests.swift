//
//  SearchOrchestratorPlannerSafetyTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Bugs 3, 11 et 8 (planner facultatif, pages uniques, sources affichées) de `SearchOrchestratorStreamingTests`.

extension SearchOrchestratorStreamingTests {
    // MARK: - Bug 3 : planner facultatif, annulation jamais avalée

    @Test("Bug 3 : le bouton Stop pendant un tour de scrape lève CancellationError — ni nouveau tour planner, ni génération finale")
    func cancellationDuringScrapeRoundStopsThePipeline() async throws {
        let scrapeLog = ScrapeLog()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog, suspendsUntilCancelled: true)
        )

        let task = Task { try await orchestrator.streamAnswer(query: "requête") }
        await streamingWaitUntil("début du premier scrape") { await !scrapeLog.urls.isEmpty }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // Avant : la page annulée revenait « en échec », le tour 3 relançait
        // le planner, puis la génération finale partait quand même.
        #expect(aiProvider.plannerPromptCount == 1)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        #expect(await scrapeLog.urls == ["https://1.example"])
    }

    @Test("Bug 3 : une annulation levée PAR le planner (URLError .cancelled d'un provider cloud coupé) remonte, au lieu du repli « done »")
    func plannerCancellationPropagates() async {
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = StreamingMockAIGenerating(plannerError: URLError(.cancelled))
        let orchestrator = makeStreamingOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let error = await #expect(throws: URLError.self) { _ = try await orchestrator.streamAnswer(query: "requête") }

        #expect(error?.code == .cancelled)
        #expect(aiProvider.plannerPromptCount == 1)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
    }

    @Test("Bug 3 : une annulation pendant la classification remonte — aucune recherche lancée sur le repli « sûr »")
    func classificationCancellationPropagates() async {
        let client = StreamingMockSearXNGClient()
        let aiProvider = StreamingMockAIGenerating(classificationError: CancellationError())
        let orchestrator = makeStreamingOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        await #expect(throws: CancellationError.self) { _ = try await orchestrator.streamAnswer(query: "requête") }

        #expect(await client.receivedQueries.isEmpty)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
    }

    @Test("isCancellation : CancellationError et URLError(.cancelled) sont des annulations ; un timeout ou une erreur de provider, non")
    func isCancellationRecognisesOnlyCancellations() {
        #expect(SearchOrchestrator.isCancellation(CancellationError()))
        #expect(SearchOrchestrator.isCancellation(URLError(.cancelled)))
        #expect(!SearchOrchestrator.isCancellation(URLError(.timedOut)))
        #expect(!SearchOrchestrator.isCancellation(StreamingMockError.searchFailed))
    }

    // MARK: - Bug 11 : chaque page scrapée au plus une fois

    @Test("Bug 11 : un planner qui redemande la même page ne la télécharge qu'une fois ; elle est annoncée « déjà récupérée » et figure une seule fois dans le prompt")
    func repeatedPlannerURLIsScrapedOnce() async throws {
        let scrapeLog = ScrapeLog()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        _ = try await orchestrator.streamAnswer(query: "requête")

        // Tour 2 : scrape de 1.example ; tour 3 : même demande, rien de neuf -> fin.
        #expect(await scrapeLog.urls == ["https://1.example"])
        #expect(aiProvider.plannerPromptCount == 2)
        let lastPlannerPrompt = try #require(aiProvider.receivedGeneratePrompts.last { $0.contains("<planner_context>") })
        #expect(lastPlannerPrompt.contains("https://1.example (page déjà récupérée)"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.components(separatedBy: "Contenu scrapé pour https://1.example").count == 2)
    }

    @Test("Bug 11 : doublons internes d'une même demande (www, slash final, fragment) — un seul téléchargement, à l'URL exacte de la source, puis fin de boucle")
    func duplicateURLsWithinOneDecisionAreScrapedOnce() async throws {
        let scrapeLog = ScrapeLog()
        let source = Self.makeResult(title: "Wiki", url: "https://www.wiki.example/page", content: "Contenu wiki")
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: [source], suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://wiki.example/page/","https://www.wiki.example/page#histoire","https://www.wiki.example/page"]}"#
        let aiProvider = StreamingMockAIGenerating(plannerResponse: planner)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        _ = try await orchestrator.streamAnswer(query: "requête")

        #expect(await scrapeLog.urls == ["https://www.wiki.example/page"])
        // L'unique source est déjà lue : plus rien à proposer, pas de tour 3.
        #expect(aiProvider.plannerPromptCount == 1)
    }

    @Test("scrapableURLs : sources affichées seulement, sans doublon ni page déjà tentée, limite comptée APRÈS le filtre, URL exacte de la source")
    func scrapableURLsFiltersBeforeLimiting() {
        let sources = ["https://a.example/x", "https://b.example", "https://c.example"].map { Self.makeResult(title: "T", url: $0, content: nil) }
        let requested = ["https://inventee.example", "https://a.example/x/#intro", "https://a.example/x", "https://b.example", "https://c.example"]
        let attempted: Set<String> = [SearchOrchestrator.urlKey("https://b.example")]

        let selected = SearchOrchestrator.scrapableURLs(requested, displayedSources: sources, alreadyAttempted: attempted, limit: 2)

        #expect(selected == ["https://a.example/x", "https://c.example"])
        #expect(SearchOrchestrator.scrapableURLs(requested, displayedSources: sources, alreadyAttempted: [], limit: 0).isEmpty)
    }

    @Test("Bug 11 : accumulate ne garde qu'un résultat par URL, y compris au sein d'un même lot")
    func accumulateDeduplicatesWithinOneBatch() {
        var sources = [Self.makeResult(title: "Déjà là", url: "https://a.example", content: nil)]
        var pages: [ScrapedPage] = []
        let batch = [
            Self.makeResult(title: "B", url: "https://b.example", content: nil),
            Self.makeResult(title: "B bis", url: "https://www.b.example/", content: nil),
            Self.makeResult(title: "A bis", url: "https://a.example#suite", content: nil),
        ]

        SearchOrchestrator.accumulate(.searchResults(batch), sources: &sources, scrapedPages: &pages)

        #expect(sources.map(\.title) == ["Déjà là", "B"])
    }

    // MARK: - Bug 8 : le planner limité aux sources affichées

    @Test("Bug 8 : le planner ne voit et ne fait télécharger que les sources affichées — ni résultat hors du top N, ni URL inventée")
    func plannerCannotScrapeUndisplayedURLs() async throws {
        let scrapeLog = ScrapeLog()
        let client = StreamingMockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://7.example","https://inventee.example/secret","https://2.example"]}"#
        let aiProvider = StreamingMockAIGenerating(plannerResponse: planner)
        let orchestrator = makeStreamingOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(await scrapeLog.urls == ["https://2.example"])
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(plannerPrompt.contains("https://5.example"))
        #expect(!plannerPrompt.contains("https://6.example"))
        // Invariant des citations : aucun document au-delà des 5 sources affichées.
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Contenu scrapé pour https://2.example"))
        #expect(!finalPrompt.contains("inventee.example"))
        #expect(!finalPrompt.contains("[6]"))
    }

    @Test("Bug 8 : sans aucune source, aucun tour planner — il n'aurait rien à choisir")
    func noSourceMeansNoPlannerRound() async throws {
        let aiProvider = StreamingMockAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeStreamingOrchestrator(failoverManager: FailoverManager(client: StreamingMockSearXNGClient(), instances: [Self.instance]), aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.isEmpty)
        #expect(aiProvider.plannerPromptCount == 0)
        #expect(aiProvider.receivedStreamPrompts.count == 1)
    }

    @Test("pagesBackedBySources : écarte toute page hors des sources affichées et recopie l'URL exacte de sa source")
    func pagesBackedBySourcesKeepsDisplayedSourcesOnly() {
        let sources = [Self.makeResult(title: "A", url: "https://www.a.example/doc", content: nil)]
        let pages = [
            ScrapedPage(url: "https://a.example/doc/#intro", title: "A", content: "contenu A", succeeded: true),
            ScrapedPage(url: "https://ailleurs.example", title: "X", content: "contenu X", succeeded: true),
        ]

        let kept = SearchOrchestrator.pagesBackedBySources(pages, sources: sources)

        #expect(kept == [ScrapedPage(url: "https://www.a.example/doc", title: "A", content: "contenu A", succeeded: true)])
    }

    @Test("plannerPrompt : sources affichées annotées (récupérée / en échec), plafond par tour interpolé, plus aucun champ reasoning demandé")
    func plannerPromptAnnotatesAttemptedSources() {
        let sources = ["https://a.example", "https://b.example", "https://c.example"].map { Self.makeResult(title: "T", url: $0, content: nil) }
        let attempted = [
            ScrapedPage(url: "https://a.example", title: "A", content: "contenu", succeeded: true),
            ScrapedPage(url: "https://b.example", title: "B", content: "", succeeded: false),
        ]

        let prompt = SearchOrchestrator.plannerPrompt(
            query: "requête",
            displayedSources: sources,
            scrapedPages: attempted,
            availableActionNames: ["scrapeURL", "done"],
            iteration: 3,
            maxIterations: 3,
            maxURLsPerIteration: 2
        )

        #expect(prompt.contains("1. T — https://a.example (page déjà récupérée)"))
        #expect(prompt.contains("2. T — https://b.example (récupération échouée, ne la redemande pas)"))
        #expect(prompt.contains("3. T — https://c.example\n"))
        #expect(prompt.contains("au plus 2 à la fois"))
        #expect(!prompt.contains("reasoning"))
    }
}
