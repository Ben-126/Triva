//
//  SearchOrchestratorPreReadTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures (privées à ce fichier, comme dans les autres suites)

/// SearXNG factice : toujours les mêmes résultats.
private actor FixedResultsClient: SearXNGSearching {
    private let results: [SearXNGSearchResult]

    init(_ results: [SearXNGSearchResult]) {
        self.results = results
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Moteur factice routé par la NATURE du prompt : classification (`<user_query>`,
/// sortie vide -> repli sûr, donc recherche web), planner (`<planner_context>`),
/// sinon rédaction, en génération directe comme en flux.
private final class PreReadAIProvider: AIGenerating {
    private(set) var plannerPrompts: [String] = []
    private(set) var finalPrompts: [String] = []
    private let plannerResponse: String
    private let answer: String

    init(plannerResponse: String = #"{"action":"done","urls":[]}"#, answer: String = "Réponse sourcée[1].") {
        self.plannerResponse = plannerResponse
        self.answer = answer
    }

    func generate(prompt: String) async throws -> String {
        if prompt.contains("<user_query>") { return "" }
        if prompt.contains("<planner_context>") {
            plannerPrompts.append(prompt)
            return plannerResponse
        }
        finalPrompts.append(prompt)
        return answer
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        finalPrompts.append(prompt)
        let answer = answer
        return AsyncThrowingStream { continuation in
            continuation.yield(answer)
            continuation.finish()
        }
    }
}

/// Journal des URLs demandées à la lecture (les lectures tournent en parallèle).
private actor PreReadScrapeLog {
    private(set) var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }
}

/// Lecture factice : réussit pour les URLs de `readable`, échoue pour les autres.
private struct ScriptedScrapeService: ScrapeServing {
    let log: PreReadScrapeLog
    var readable: Set<String> = []

    func scrape(url: String) async -> ScrapedPage {
        await log.record(url)
        guard readable.contains(url) else { return ScrapedPage(url: url, title: url, content: "", succeeded: false) }
        return ScrapedPage(url: url, title: "Page lue", content: "Contenu lu pour \(url)", succeeded: true)
    }
}

/// Page qui ne répond jamais : seule l'échéance de la lecture la libère.
private struct UnansweredScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        try? await Task.sleep(for: .seconds(120))
        return ScrapedPage(url: url, title: url, content: "", succeeded: false)
    }
}

private struct ConstantSimilarity: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

private struct NoDuplicate: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

private struct NoLanguage: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

// MARK: - Suite

/// Mission A1, décision (a) de Ben : les sources retenues SANS extrait (repli
/// cloud : OpenAI ne rend que des URL) sont lues sans LLM, dans tous les modes,
/// en temps borné ; celles qui restent illisibles ne sont pas citables, et ne
/// sont jamais renumérotées.
@MainActor
@Suite("SearchOrchestrator — lecture des sources sans extrait (mission A1)")
struct SearchOrchestratorPreReadTests {
    private static func result(_ url: String, title: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: content,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    private static func orchestrator(
        _ results: [SearXNGSearchResult],
        mode: ResponseMode,
        ai: PreReadAIProvider,
        scrapeService: any ScrapeServing,
        scrapeRoundTimeout: Duration = SearchOrchestrator.defaultScrapeRoundTimeout
    ) -> SearchOrchestrator {
        SearchOrchestrator(
            failoverManager: FailoverManager(client: FixedResultsClient(results), instances: [URL(string: "https://searxng.example")!]),
            aiProvider: ai,
            responseMode: mode,
            scrapeService: scrapeService,
            sourceRanker: SourceRanker(relevanceScorer: ConstantSimilarity(), duplicateScorer: NoDuplicate(), languageIdentifier: NoLanguage()),
            scrapeRoundTimeout: scrapeRoundTimeout,
            widgets: []
        )
    }

    // MARK: Mode Rapide (aucun planner)

    @Test("Rapide : la source sans extrait est lue sans LLM, son contenu arrive sous [1] ; la source avec extrait n'est pas lue")
    func quickModeReadsSourcesWithoutExcerpt() async throws {
        let log = PreReadScrapeLog()
        let ai = PreReadAIProvider()
        let results = [
            Self.result("https://a.example", title: "Titre A", content: nil),
            Self.result("https://b.example", title: "Titre B", content: "Extrait B"),
        ]
        let orchestrator = Self.orchestrator(
            results, mode: .quick, ai: ai, scrapeService: ScriptedScrapeService(log: log, readable: ["https://a.example"])
        )

        let answer = try await orchestrator.streamAnswer(query: "question")

        #expect(await log.urls == ["https://a.example"])
        #expect(ai.plannerPrompts.isEmpty)
        let prompt = try #require(ai.finalPrompts.first)
        #expect(prompt.contains("[1] Titre A — https://a.example\nContenu de la page : Contenu lu pour https://a.example"))
        #expect(prompt.contains("[2] Titre B — https://b.example\nExtrait : Extrait B"))
        #expect(answer.artifacts.uncitableSourceNumbers.isEmpty)
        #expect(answer.artifacts.citableSourceCount == 2)
    }

    @Test("Rapide : lecture en échec -> source absente du prompt (ni titre ni URL), [1] non citable, ordre des sources inchangé")
    func quickModeFailedReadMakesTheSourceUncitable() async throws {
        let log = PreReadScrapeLog()
        let ai = PreReadAIProvider()
        let results = [
            Self.result("https://a.example", title: "Titre A", content: nil),
            Self.result("https://b.example", title: "Titre B", content: "Extrait B"),
        ]
        let orchestrator = Self.orchestrator(results, mode: .quick, ai: ai, scrapeService: ScriptedScrapeService(log: log))

        let answer = try await orchestrator.streamAnswer(query: "question")

        let prompt = try #require(ai.finalPrompts.first)
        #expect(!prompt.contains("Titre A"))
        #expect(!prompt.contains("https://a.example"))
        #expect(prompt.contains(PromptTemplates.numberingGapNote))
        #expect(prompt.contains("[2] Titre B — https://b.example"))
        #expect(answer.artifacts.sources.map(\.url) == ["https://a.example", "https://b.example"])
        #expect(answer.artifacts.uncitableSourceNumbers == [1])
        #expect(answer.artifacts.citableSourceCount == 2)
    }

    @Test("Rapide : aucune page lisible -> contexte exactement « Aucune source disponible. »")
    func quickModeWithNothingReadableGivesTheNoSourcesContext() async throws {
        let ai = PreReadAIProvider()
        let results = [
            Self.result("https://a.example", title: "Titre A", content: nil),
            Self.result("https://b.example", title: "Titre B", content: "  "),
        ]
        let orchestrator = Self.orchestrator(results, mode: .quick, ai: ai, scrapeService: ScriptedScrapeService(log: PreReadScrapeLog()))

        let answer = try await orchestrator.streamAnswer(query: "question")

        let prompt = try #require(ai.finalPrompts.first)
        #expect(prompt.contains("<contexte>\n\(PromptTemplates.noSourcesContext)\n</contexte>"))
        #expect(answer.artifacts.citableSourceCount == 0)
        #expect(answer.artifacts.uncitableSourceNumbers == [1, 2])
    }

    @Test("Rapide : la lecture est bornée — une page qui ne répond pas devient non citable à l'échéance", .timeLimit(.minutes(1)))
    func quickModeReadIsBounded() async throws {
        let ai = PreReadAIProvider()
        let results = [
            Self.result("https://lente.example", title: "Page lente", content: nil),
            Self.result("https://b.example", title: "Titre B", content: "Extrait B"),
        ]
        let orchestrator = Self.orchestrator(
            results, mode: .quick, ai: ai, scrapeService: UnansweredScrapeService(), scrapeRoundTimeout: .milliseconds(100)
        )

        let answer = try await orchestrator.streamAnswer(query: "question")

        #expect(answer.artifacts.uncitableSourceNumbers == [1])
        #expect(ai.finalPrompts.first?.contains("Page lente") == false)
    }

    // MARK: Autres modes

    @Test("Approfondi : une page déjà lue n'est jamais redemandée par le planner")
    func plannerNeverRereadsAPreReadPage() async throws {
        let log = PreReadScrapeLog()
        let planner = #"{"action":"scrapeURL","urls":["https://a.example","https://b.example"]}"#
        let ai = PreReadAIProvider(plannerResponse: planner)
        let results = [
            Self.result("https://a.example", title: "Titre A", content: nil),
            Self.result("https://b.example", title: "Titre B", content: "Extrait B"),
        ]
        let readable: Set<String> = ["https://a.example", "https://b.example"]
        let orchestrator = Self.orchestrator(results, mode: .deep, ai: ai, scrapeService: ScriptedScrapeService(log: log, readable: readable))

        _ = try await orchestrator.streamAnswer(query: "question")

        #expect(await log.urls == ["https://a.example", "https://b.example"])
        let firstPlannerPrompt = try #require(ai.plannerPrompts.first)
        #expect(firstPlannerPrompt.contains("https://a.example (page déjà récupérée)"))
    }

    @Test("Approfondi : toutes les sources déjà lues -> aucun tour planner, donc aucun appel LLM de plus")
    func everySourcePreReadSkipsThePlanner() async throws {
        let ai = PreReadAIProvider(plannerResponse: #"{"action":"scrapeURL","urls":["https://a.example"]}"#)
        let results = [
            Self.result("https://a.example", title: "Titre A", content: nil),
            Self.result("https://b.example", title: "Titre B", content: nil),
        ]
        let scrape = ScriptedScrapeService(log: PreReadScrapeLog(), readable: ["https://a.example"])
        let orchestrator = Self.orchestrator(results, mode: .deep, ai: ai, scrapeService: scrape)

        _ = try await orchestrator.streamAnswer(query: "question")

        #expect(ai.plannerPrompts.isEmpty)
        #expect(ai.finalPrompts.count == 1)
    }

    @Test("Fiable : sources fiables toutes illisibles -> aucune génération (état sans source fiable)")
    func reliableModeWithOnlyUnreadableSourcesGeneratesNothing() async throws {
        let ai = PreReadAIProvider()
        let results = [Self.result("https://fr.wikipedia.org/wiki/TypeScript", title: "TypeScript — Wikipédia", content: nil)]
        let orchestrator = Self.orchestrator(results, mode: .reliable, ai: ai, scrapeService: ScriptedScrapeService(log: PreReadScrapeLog()))

        let answer = try await orchestrator.streamAnswer(query: "question")

        #expect(answer.artifacts.sources.count == 1)
        #expect(answer.artifacts.lacksReliableSources)
        #expect(ai.finalPrompts.isEmpty)
    }

    @Test("answer() en Fiable : réponse sans page lue citée -> vide, comme sans source ; réponse citée -> gardée")
    func nonStreamingReliableAnswerIsCheckedToo() async throws {
        let results = [Self.result("https://fr.wikipedia.org/wiki/TypeScript", title: "TypeScript — Wikipédia", content: "Langage typé.")]
        let scrape = ScriptedScrapeService(log: PreReadScrapeLog())

        let uncited = try await Self.orchestrator(
            results, mode: .reliable, ai: PreReadAIProvider(answer: "Réponse de tête."), scrapeService: scrape
        ).answer(query: "question")
        let cited = try await Self.orchestrator(
            results, mode: .reliable, ai: PreReadAIProvider(answer: "TypeScript est typé[1]."), scrapeService: scrape
        ).answer(query: "question")

        #expect(uncited.answer.isEmpty)
        #expect(uncited.sources.count == 1)
        #expect(cited.answer == "TypeScript est typé[1].")
    }

    // MARK: Fonctions pures

    @Test("Sources sans extrait : nil, vide ou blanc ; dans l'ordre, une fois par URL normalisée")
    func sourcesWithoutExcerptSelection() {
        let sources = [
            Self.result("https://a.example", title: "A", content: nil),
            Self.result("https://b.example", title: "B", content: "Extrait"),
            Self.result("https://c.example", title: "C", content: " \n "),
            Self.result("https://www.a.example/", title: "A bis", content: ""),
        ]

        #expect(SearchOrchestrator.sourcesWithoutExcerpt(sources) == ["https://a.example", "https://c.example"])
    }

    @Test("Échéance : 8 s au plus en Rapide (ou moins si l'échéance injectée l'est), celle d'un tour du planner sinon")
    func preReadTimeoutFollowsTheMode() {
        let round = SearchOrchestrator.defaultScrapeRoundTimeout

        #expect(SearchOrchestrator.preReadTimeout(for: .quick, scrapeRoundTimeout: round) == .seconds(8))
        #expect(SearchOrchestrator.preReadTimeout(for: .quick, scrapeRoundTimeout: .seconds(2)) == .seconds(2))
        #expect(SearchOrchestrator.preReadTimeout(for: .deep, scrapeRoundTimeout: round) == round)
        #expect(SearchOrchestrator.preReadTimeout(for: .reliable, scrapeRoundTimeout: round) == round)
    }
}
