//
//  UploadsSearchPipelineTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Fichiers joints dans le pipeline de recherche (I1b)

/// Provider IA factice du pipeline : réponse choisie selon la NATURE du
/// prompt, comme `MockAIGenerating` de `SearchOrchestratorTests.swift`
/// (dupliqué : `private` est scopé au fichier) — `<user_query>` pour la
/// classification, `<planner_context>` pour le planner, le reste pour la
/// réponse finale.
private final class PipelineAIProvider: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let classifyResponse: String
    private var plannerResponses: [String]

    init(classifyResponse: String, plannerResponses: [String] = []) {
        self.classifyResponse = classifyResponse
        self.plannerResponses = plannerResponses
    }

    var plannerPrompts: [String] {
        receivedPrompts.filter { $0.contains("<planner_context>") }
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        if prompt.contains("<user_query>") { return classifyResponse }
        if prompt.contains("<planner_context>") { return plannerResponses.isEmpty ? "" : plannerResponses.removeFirst() }
        return "réponse"
    }
}

/// Client SearXNG à réponse fixe, qui compte ses appels.
private actor FixedSearXNGClient: SearXNGSearching {
    private let results: [SearXNGSearchResult]
    private(set) var callCount = 0

    init(results: [SearXNGSearchResult] = []) {
        self.results = results
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        return SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Classement déterministe : similarité constante (l'ordre du moteur
/// décide), jamais de quasi-doublon, aucune langue reconnue.
private struct ConstantScorer: TextSimilarityScoring {
    let score: Double

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: score, count: candidates.count)
    }
}

private struct NoLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

private func webResult(_ name: String) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: "Web \(name)",
        url: "https://\(name).example",
        content: "Extrait \(name)",
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

private func classificationJSON(personalSearch: Bool, standaloneFollowUp: String) -> String {
    #"{"classification":{"skipSearch":false,"personalSearch":\#(personalSearch),"academicSearch":false,"discussionSearch":false,"#
        + #""showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"\#(standaloneFollowUp)"}"#
}

@MainActor
private func makePipeline(client: FixedSearXNGClient, aiProvider: PipelineAIProvider, responseMode: ResponseMode) -> SearchOrchestrator {
    SearchOrchestrator(
        failoverManager: FailoverManager(client: client, instances: [uploadsTestInstance]),
        aiProvider: aiProvider,
        responseMode: responseMode,
        scrapeService: UploadsUnusedScrapeService(),
        sourceRanker: SourceRanker(
            relevanceScorer: ConstantScorer(score: 0.5),
            duplicateScorer: ConstantScorer(score: 0),
            languageIdentifier: NoLanguageIdentifier()
        ),
        widgets: []
    )
}

@MainActor
@Suite("Fichiers joints dans le pipeline de recherche")
struct UploadsSearchPipelineTests {
    @Test("personalSearch + fichier joint : seuls les fichiers sont consultés — aucun appel SearXNG ni planner, document cité en [1]")
    func personalSearchWithAttachmentsSearchesOnlyTheFiles() async throws {
        let attachment = uploadsMakeAttachment("contrat.pdf", chunks: ["Le préavis est de trois mois.", "La clause 7 traite des pénalités."], pages: [1...1, 2...2])
        let scorer = UploadsTableScorer(["préavis du contrat": ["Le préavis est de trois mois.": 0.9, "La clause 7 traite des pénalités.": 0.1]])
        let client = FixedSearXNGClient(results: [webResult("a")])
        let aiProvider = PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: true, standaloneFollowUp: "préavis du contrat"))
        let orchestrator = makePipeline(client: client, aiProvider: aiProvider, responseMode: .deep)

        let result = try await orchestrator.answer(
            query: "Quel est le préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: scorer)
        )

        #expect(await client.callCount == 0)
        #expect(aiProvider.plannerPrompts.isEmpty)
        #expect(result.sources.map(\.url) == [UploadsSearchResultBuilder.sourceURL(for: attachment.id)])
        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(result.artifacts.citableSourceCount == 1)
        #expect(result.artifacts.searchPerformed)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[1] contrat.pdf"))
        #expect(finalPrompt.contains("Le préavis est de trois mois."))
    }

    @Test("Mode Fiable : les fichiers joints restent des sources — le filtre « domaines fiables » ne concerne que le web")
    func reliableModeKeepsAttachmentSources() async throws {
        let attachment = uploadsMakeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let client = FixedSearXNGClient()
        let aiProvider = PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: true, standaloneFollowUp: "préavis"))
        let orchestrator = makePipeline(client: client, aiProvider: aiProvider, responseMode: .reliable)

        let result = try await orchestrator.answer(
            query: "Quel préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: UploadsTableScorer([:]))
        )

        #expect(result.sources.map(\.title) == ["notes.txt"])
        #expect(await client.callCount == 0)
    }

    /// Décision (b) de Ben : les fichiers joints sont consultés dès le tour
    /// seedé, avec la reformulation, et le planner ne les propose plus — avant,
    /// ils n'étaient lus que si le planner choisissait `uploadsSearch`.
    @Test("Recherche web + fichiers joints sans personalSearch : fichiers consultés dès le tour seedé (reformulation), jamais par le planner ; documents en tête, puis le web")
    func webRouteConsultsAttachmentsFromTheSeedNotThePlanner() async throws {
        let attachment = uploadsMakeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let log = UploadsQueryLog()
        let scorer = UploadsTableScorer(["durée du préavis": ["Le préavis est de trois mois.": 0.9]], log: log)
        let client = FixedSearXNGClient(results: [webResult("a"), webResult("b")])
        let aiProvider = PipelineAIProvider(
            classifyResponse: classificationJSON(personalSearch: false, standaloneFollowUp: "durée du préavis"),
            plannerResponses: [#"{"action":"done","urls":[]}"#]
        )
        let orchestrator = makePipeline(client: client, aiProvider: aiProvider, responseMode: .deep)

        let result = try await orchestrator.answer(
            query: "Quelle est la durée du préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: scorer)
        )

        #expect(await client.callCount == 1)
        #expect(result.sources.map(\.url) == [UploadsSearchResultBuilder.sourceURL(for: attachment.id), "https://a.example", "https://b.example"])
        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(await log.references == ["durée du préavis"])
        let plannerPrompts = aiProvider.plannerPrompts
        #expect(plannerPrompts.count == 1)
        #expect(plannerPrompts.allSatisfy { !$0.contains("uploadsSearch") })
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[1] notes.txt"))
        #expect(finalPrompt.contains("[2] Web a"))
    }

    @Test("Budget des fichiers joints : 6 000 caractères quand ils sont seuls, la moitié quand ils s'ajoutent à une recherche web")
    func attachmentBudgetDependsOnTheRoute() async throws {
        let longText = String(repeating: "Le préavis est de trois mois. ", count: 400)
        let attachment = uploadsMakeAttachment("long.txt", chunks: [longText])
        let index = AttachmentSearchIndex(attachments: [attachment], scorer: UploadsTableScorer([:]))

        let alone = makePipeline(
            client: FixedSearXNGClient(),
            aiProvider: PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: true, standaloneFollowUp: "préavis")),
            responseMode: .deep
        )
        let aloneResult = try await alone.answer(query: "Quel préavis ?", attachments: index)

        let mixed = makePipeline(
            client: FixedSearXNGClient(results: [webResult("a")]),
            aiProvider: PipelineAIProvider(
                classifyResponse: classificationJSON(personalSearch: false, standaloneFollowUp: "préavis"),
                plannerResponses: [#"{"action":"uploadsSearch","queries":["préavis"]}"#]
            ),
            responseMode: .deep
        )
        let mixedResult = try await mixed.answer(query: "Quel préavis ?", attachments: index)

        let aloneCount = try #require(aloneResult.sources.first?.content?.count)
        let mixedCount = try #require(mixedResult.sources.first?.content?.count)
        #expect(aloneCount > UploadsSearchResultBuilder.defaultMaxTotalCharacters / 2)
        #expect(aloneCount <= UploadsSearchResultBuilder.defaultMaxTotalCharacters)
        #expect(mixedCount <= UploadsSearchResultBuilder.defaultMaxTotalCharacters / 2)
    }

    /// Décision (b) de Ben (2026-10-29) : le classifieur ne sait pas que des
    /// fichiers sont joints, et le mode Rapide n'a pas de planner. Avant, ce
    /// test figeait « fichiers joints non consultés » ; ils le sont désormais
    /// toujours, sans couper la recherche web que la classification demande.
    @Test("Mode Rapide sans personalSearch : fichiers joints consultés quand même, à côté de la recherche web")
    func quickModeConsultsAttachmentsAlongsideTheWeb() async throws {
        let attachment = uploadsMakeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let log = UploadsQueryLog()
        let client = FixedSearXNGClient(results: [webResult("a")])
        let orchestrator = makePipeline(
            client: client,
            aiProvider: PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: false, standaloneFollowUp: "préavis")),
            responseMode: .quick
        )

        let result = try await orchestrator.answer(
            query: "Quel préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: UploadsTableScorer([:], log: log))
        )

        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(result.sources.map(\.url) == [UploadsSearchResultBuilder.sourceURL(for: attachment.id), "https://a.example"])
        #expect(await log.references == ["préavis"])
        #expect(await client.callCount == 1)
    }

    @Test("Question sans recherche (skipSearch) avec un fichier joint : fichiers consultés, aucun appel SearXNG")
    func skippedSearchStillConsultsAttachments() async throws {
        let attachment = uploadsMakeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let client = FixedSearXNGClient(results: [webResult("a")])
        let skipJSON = #"{"classification":{"skipSearch":true,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"#
            + #""showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"résume"}"#
        let orchestrator = makePipeline(client: client, aiProvider: PipelineAIProvider(classifyResponse: skipJSON), responseMode: .quick)

        let result = try await orchestrator.answer(
            query: "Résume-le",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: UploadsTableScorer([:]))
        )

        #expect(await client.callCount == 0)
        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(result.artifacts.searchPerformed)
    }

    @Test("Routage (b) : seule la route « aucune recherche » change, et seulement avec des fichiers joints")
    func routeConsultingAttachmentsOnlyRewritesTheNoSearchRoute() {
        #expect(SearchOrchestrator.routeConsultingAttachments(.none, hasAttachments: true) == .attachments)
        #expect(SearchOrchestrator.routeConsultingAttachments(.none, hasAttachments: false) == SearchRoute.none)
        #expect(SearchOrchestrator.routeConsultingAttachments(.web(.academic), hasAttachments: true) == .web(.academic))
        #expect(SearchOrchestrator.routeConsultingAttachments(.webUnlessWeatherAnswered, hasAttachments: true) == .webUnlessWeatherAnswered)
        #expect(SearchOrchestrator.routeConsultingAttachments(.attachments, hasAttachments: true) == .attachments)
    }
}

// MARK: - Budget Apple Intelligence avec fichiers joints ET widgets (I1b, bug 6)

/// Pages scrapées pleines : le plafond par page de `ScrapeService`.
private struct FullPageScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        let content = String(String(repeating: "Contenu complet de la page scrapée. ", count: 200).prefix(ScrapeService.defaultMaxContentCharactersPerPage))
        return ScrapedPage(url: url, title: "Page \(url)", content: content, succeeded: true)
    }
}

/// Widget toujours exécuté, au contexte fixe.
private struct AlwaysOnWidget: SearchWidget {
    let kind: SearchWidgetKind
    let llmContext: String

    func shouldExecute(for classification: QueryClassification) -> Bool { true }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        SearchWidgetOutput(kind: kind, llmContext: llmContext)
    }
}

extension UploadsSearchPipelineTests {
    /// Les deux plus longs contextes que les vrais services peuvent produire :
    /// nom de lieu long (« ville, région, pays » d'Open-Meteo) et expression
    /// au plafond de `CalculationExpressionEvaluator` (256 caractères).
    private static func longestWidgetContexts() -> (weather: String, calculation: String) {
        let weather = WeatherWidgetService.llmContext(for: WeatherWidgetData(
            location: WeatherLocation(name: String(repeating: "Saint-Rémy-en-Bouzemont ", count: 3) + ", Grand Est, France", latitude: 48.6, longitude: 4.6),
            condition: WeatherCondition(label: "Orage avec grêle forte", systemImageName: "cloud.bolt.rain"),
            currentTemperatureCelsius: -40,
            apparentTemperatureCelsius: -48,
            relativeHumidityPercent: 100,
            windSpeedKmh: 150,
            isDaytime: true,
            todayMinTemperatureCelsius: -45,
            todayMaxTemperatureCelsius: -38
        ))
        let calculation = CalculationWidgetService.llmContext(for: CalculationWidgetData(
            expression: String(repeating: "12+", count: 85) + "1",
            result: 1021,
            formattedResult: "123 456 789 012,0123456789"
        ))
        return (weather, calculation)
    }

    /// Le pire cas de `appleIntelligenceWorstCaseFitsTheContextWindow`
    /// (PromptTemplatesTests) — historique long, question et reformulation de
    /// 300 caractères, extraits de 300 caractères, pages scrapées pleines —,
    /// mené de bout en bout, PLUS ce qu'I1b ajoute au prompt : 10 fichiers
    /// joints, consultés dès le tour seedé depuis la décision (b) de Ben (5
    /// extraits au plus entrent dans le prompt,
    /// `SearchOrchestrator.attachmentFragmentLimit`), et les deux widgets à
    /// leur plus long. Même borne que le pire cas d'I1a. Avant le partage du
    /// budget des pages (`scrapedContextBudget`) et ce plancher d'extraits :
    /// 11 269 caractères mesurés, 10 documents de 150 caractères. Après :
    /// 9 328 (mesure du 29/10/2026, fichiers alors lus par le planner — même
    /// budget, moitié de `maxScrapedContextCharacters`).
    @Test("Apple Intelligence, pire cas avec fichiers joints (tour seedé) et deux widgets : prompt final sous 10 000 caractères")
    func appleIntelligenceWorstCaseWithAttachmentsAndWidgetsFits() async throws {
        let long = String(repeating: "La photosynthèse convertit l'énergie lumineuse en énergie chimique. ", count: 30)
        let snippet = String(long.prefix(300))
        let webResults = (1...7).map { index in
            SearXNGSearchResult(
                title: "Source web \(index)", url: "https://\(index).example", content: snippet,
                imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            )
        }
        // Un texte DISTINCT par fichier : `UploadsSearchResultBuilder.deduplicated`
        // retire les fragments au texte identique (même document joint deux
        // fois). Avec dix fragments identiques, un seul document survivait et le
        // test mesurait un cas bien plus léger que le pire cas annoncé.
        let attachments = (1...10).map { index in
            uploadsMakeAttachment("document-\(index).txt", chunks: ["Document \(index). " + String(long.prefix(600))])
        }
        let standalone = String(repeating: "rendement photosynthèse ", count: 15)
        let classifyResponse = #"{"classification":{"skipSearch":false,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"#
            + #""showWeatherWidget":true,"showStockWidget":false,"showCalculationWidget":true},"standaloneFollowUp":"\#(standalone)"}"#
        let aiProvider = PipelineAIProvider(
            classifyResponse: classifyResponse,
            plannerResponses: [#"{"action":"scrapeURL","urls":["https://1.example","https://2.example"]}"#]
        )
        let contexts = Self.longestWidgetContexts()
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: FixedSearXNGClient(results: webResults), instances: [uploadsTestInstance]),
            aiProvider: aiProvider,
            responseMode: .deep,
            configuration: .appleIntelligence,
            scrapeService: FullPageScrapeService(),
            sourceRanker: SourceRanker(
                relevanceScorer: ConstantScorer(score: 0.5),
                duplicateScorer: ConstantScorer(score: 0),
                languageIdentifier: NoLanguageIdentifier()
            ),
            widgets: [
                AlwaysOnWidget(kind: .weather, llmContext: contexts.weather),
                AlwaysOnWidget(kind: .calculation, llmContext: contexts.calculation),
            ]
        )
        let history = (0..<10).map { ClassifierChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: long) }

        let result = try await orchestrator.answer(
            query: String(long.prefix(300)),
            chatHistory: history,
            attachments: AttachmentSearchIndex(attachments: attachments, scorer: UploadsTableScorer([:]))
        )

        // Le pire cas est bien atteint : autant de documents que le budget en
        // admet (1 500 caractères ÷ 300), pages et widgets.
        #expect(result.artifacts.attachmentSourceCount == 5)
        #expect(result.artifacts.widgets.count == 2)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu de la page : "))
        #expect(finalPrompt.contains("<donnees_widgets>"))
        #expect(finalPrompt.count < 10_000, "pire cas mesuré : \(finalPrompt.count) caractères")
    }

    @Test("Budget long partagé : le contenu des fichiers joints est retranché du budget des pages scrapées, jamais sous 0")
    func attachmentContentIsDeductedFromTheScrapedBudget() {
        let document = SearXNGSearchResult(
            title: "notes.txt", url: UploadsSearchResultBuilder.sourceURL(for: UUID()), content: String(repeating: "a", count: 1_200),
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )

        #expect(SearchOrchestrator.scrapedContextBudget(total: 3_000, attachmentSources: []) == 3_000)
        #expect(SearchOrchestrator.scrapedContextBudget(total: 3_000, attachmentSources: [document]) == 1_800)
        #expect(SearchOrchestrator.scrapedContextBudget(total: 1_000, attachmentSources: [document]) == 0)
    }

    @Test("Extraits de fichiers joints : 300 caractères au moins chacun — 5 sous 1 500 (Apple Intelligence + web), 8 sous 2 500, 10 dès 3 000, jamais 0")
    func attachmentFragmentLimitKeepsExcerptsUseful() {
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 1_500) == 5)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 2_500) == 8)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 3_000) == UploadsSearchResultBuilder.defaultMaxFragments)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 6_000) == UploadsSearchResultBuilder.defaultMaxFragments)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 100) == 1)
    }
}
