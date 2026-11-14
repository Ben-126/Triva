//
//  SearchRankedSourcesRelevanceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Mission C1, R1-2 : la chaîne juge la pertinence sur la réponse BRUTE du moteur ; le classement
/// peut ensuite écarter le seul résultat pertinent. Le verdict est donc rejugé sur les sources
/// classées réellement utilisées.
@Suite("Pertinence des sources classées (mission C1, R1-2)")
struct SearchRankedSourcesRelevanceTests {
    private static let question = "Quelle est la hauteur de la tour Eiffel ?"

    private static func source(_ title: String, content: String) -> SearXNGSearchResult {
        ChainFixtures.result(title, url: "https://fr.wikipedia.org/wiki/\(title.replacingOccurrences(of: " ", with: "_"))", content: content)
    }

    private static let onTopic = source("Tour Eiffel", content: "La tour Eiffel mesure 330 mètres de hauteur.")
    private static let offTopic = source("Cuisine", content: "Recettes de cuisine traditionnelle.")

    // MARK: Fonction pure

    @Test("Chaîne présente, sources classées toutes hors sujet : le verdict favorable devient « hors sujet »")
    func downgradesAFavourableVerdict() {
        let rejudged = SearchOrchestrator.report(WebSearchChainReport(), rejudgedOn: [Self.offTopic], query: Self.question, hasChain: true)

        #expect(!rejudged.matchesQuestion)
    }

    @Test("Une source classée pertinente suffit : verdict inchangé")
    func keepsTheVerdictWhenOneRankedSourceMatches() {
        let rejudged = SearchOrchestrator.report(WebSearchChainReport(), rejudgedOn: [Self.offTopic, Self.onTopic], query: Self.question, hasChain: true)

        #expect(rejudged.matchesQuestion)
    }

    @Test("Sans chaîne, sans source, ou déjà négatif : rendu tel quel")
    func leavesOtherCasesAlone() {
        var negative = WebSearchChainReport()
        negative.matchesQuestion = false
        let positive = WebSearchChainReport()

        #expect(SearchOrchestrator.report(positive, rejudgedOn: [Self.offTopic], query: Self.question, hasChain: false) == positive)
        #expect(SearchOrchestrator.report(positive, rejudgedOn: [], query: Self.question, hasChain: true) == positive)
        #expect(SearchOrchestrator.report(negative, rejudgedOn: [Self.onTopic], query: Self.question, hasChain: true) == negative)
    }

    @Test("Les passages écartés de la chaîne sont conservés")
    func keepsThePassedOverSources() {
        var report = WebSearchChainReport()
        report.passedOver = [WebSearchSourceFailure(source: .tavily, reason: .noUsableAnswer)]

        let rejudged = SearchOrchestrator.report(report, rejudgedOn: [Self.offTopic], query: Self.question, hasChain: true)

        #expect(rejudged.passedOver == report.passedOver)
    }

    // MARK: Pipeline

    /// Inverse la pertinence : la source qui parle d'Eiffel est classée dernière, donc écartée par le top N.
    private struct EiffelLastScorer: TextSimilarityScoring {
        func similarities(of reference: String, against candidates: [String]) async -> [Double] {
            candidates.map { $0.contains("Eiffel") ? 0 : 1 }
        }
    }

    private struct NeverDuplicateScorer: TextSimilarityScoring {
        func similarities(of reference: String, against candidates: [String]) async -> [Double] {
            Array(repeating: 0, count: candidates.count)
        }
    }

    private struct NoLanguage: TextLanguageIdentifying {
        func dominantLanguage(of text: String) -> String? { nil }
    }

    private struct NoScrape: ScrapeServing {
        func scrape(url: String) async -> ScrapedPage { ScrapedPage(url: url, title: "", content: "", succeeded: false) }
    }

    @MainActor
    private func answer(mode: ResponseMode) async throws -> SearchOrchestratorResult {
        let others = (1...6).map { Self.source("Sujet \($0)", content: "Article numéro \($0) sans rapport.") }
        let provider = ScriptedWebSearchProvider(kind: .tavily, outcome: .results(others + [Self.onTopic]))
        let chain = WebSearchChain(keyedProviders: [provider], searxng: nil, openSourceProviders: { _ in [] })
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance]),
            aiProvider: PipelineMockAIGenerating(),
            responseMode: mode,
            configuration: .cloud,
            scrapeService: NoScrape(),
            sourceRanker: SourceRanker(
                relevanceScorer: EiffelLastScorer(),
                duplicateScorer: NeverDuplicateScorer(),
                languageIdentifier: NoLanguage()
            ),
            widgets: [],
            webSearchChain: chain
        )
        return try await orchestrator.answer(query: Self.question)
    }

    @MainActor
    @Test("Fiable : le classement écarte l'unique résultat pertinent, la réponse est refusée « aucune source fiable » (échoue sans le correctif)")
    func reliableRefusesWhenTheRankingDropsTheOnlyRelevantResult() async throws {
        let result = try await answer(mode: .reliable)

        #expect(!result.sources.contains(Self.onTopic))
        #expect(!result.artifacts.webSearchReport.matchesQuestion)
        #expect(result.artifacts.lacksReliableSources)
        #expect(result.answer.isEmpty)
    }

    @MainActor
    @Test("Rapide : même constat sur le verdict (le rappel hors-sujet du prompt se déclenche), la réponse n'est pas retenue par le code")
    func quickFlagsTheOffTopicSources() async throws {
        let result = try await answer(mode: .quick)

        #expect(!result.artifacts.webSearchReport.matchesQuestion)
        #expect(!result.artifacts.lacksReliableSources)
    }
}
