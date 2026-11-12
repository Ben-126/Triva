//
//  SearchOrchestratorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 06/09/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockError: Error, Sendable, Equatable {
    case searchFailed
    case generationFailed
}

/// Client SearXNG factice, même principe que `MockSearXNGClient` dans
/// FailoverManagerTests.swift : renvoie une réponse fixe, ou lève une erreur
/// si configuré pour échouer — sans le moindre appel réseau réel. Capture
/// aussi les options reçues et le nombre d'appels : nécessaire depuis 1.2
/// pour vérifier QUELLE action a été sélectionnée (moteurs forcés par
/// `AcademicSearchAction`/`SocialSearchAction`) et QUE `.skip` ne déclenche
/// aucun appel. `forcedEnginesResponse` (bug 5) : réponse d'une requête à
/// moteurs forcés (`engines` non vide), pour simuler un moteur bloqué — HTTP
/// 200 sans résultat — pendant que les moteurs par défaut répondent.
private actor MockSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private let forcedEnginesResponse: SearXNGSearchResponse?
    private let shouldFail: Bool
    private(set) var receivedOptions: [SearXNGSearchOptions] = []
    private(set) var receivedQueries: [String] = []
    private(set) var callCount = 0

    init(
        response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []),
        forcedEnginesResponse: SearXNGSearchResponse? = nil,
        shouldFail: Bool = false
    ) {
        self.response = response
        self.forcedEnginesResponse = forcedEnginesResponse
        self.shouldFail = shouldFail
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        receivedOptions.append(options)
        receivedQueries.append(query)
        if shouldFail {
            throw MockError.searchFailed
        }
        if let forcedEnginesResponse, !options.engines.isEmpty {
            return forcedEnginesResponse
        }
        return response
    }
}

/// `ScrapeServing` factice à réponse fixe, pour tester la boucle planner
/// (`scrapeURL`) sans réseau réel.
private struct MockScrapeService: ScrapeServing {
    let succeeded: Bool

    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "Titre scrapé", content: "Contenu scrapé pour \(url)", succeeded: succeeded)
    }
}

/// Provider IA factice qui route sa réponse selon la NATURE du prompt reçu
/// plutôt qu'une file d'attente positionnelle (un compte d'appels change
/// selon le chemin emprunté — ex. `.skip` ne fait aucun appel planner —
/// une file positionnelle assignerait alors la mauvaise réponse au mauvais
/// appel) : le prompt de classification contient `<user_query>`
/// (`QueryClassifier.buildPrompt`), celui du planner contient
/// `<planner_context>` (`SearchOrchestrator.plannerPrompt`), tout le reste
/// est la génération finale. `classifyResponse` vide (défaut) fait retomber
/// `QueryClassifier.parse` sur son repli sûr complet (tous les booléens à
/// false) — `primaryAction` vaut alors `.webSearch`, le cas le plus utile
/// par défaut pour tester le pipeline sans configurer une classification à
/// la main à chaque test. `plannerResponses` vide fait pareil retomber sur
/// "done" dès le premier tour planner (`decideNextAction` tolérant).
/// `plannerError` (bug 3) : erreur levée à CHAQUE tour planner.
private final class MockAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let classifyResponse: String
    private var plannerResponses: [String]
    private let finalAnswerResponse: String
    private let shouldFailFinalGeneration: Bool
    private let shouldFailClassification: Bool
    private let plannerError: (any Error)?

    init(
        classifyResponse: String = "",
        plannerResponses: [String] = [],
        finalAnswerResponse: String = "réponse factice",
        shouldFailFinalGeneration: Bool = false,
        shouldFailClassification: Bool = false,
        plannerError: (any Error)? = nil
    ) {
        self.classifyResponse = classifyResponse
        self.plannerResponses = plannerResponses
        self.finalAnswerResponse = finalAnswerResponse
        self.shouldFailFinalGeneration = shouldFailFinalGeneration
        self.shouldFailClassification = shouldFailClassification
        self.plannerError = plannerError
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)

        if prompt.contains("<user_query>") {
            if shouldFailClassification {
                throw MockError.generationFailed
            }
            return classifyResponse
        }
        if prompt.contains("<planner_context>") {
            if let plannerError { throw plannerError }
            return plannerResponses.isEmpty ? "" : plannerResponses.removeFirst()
        }
        if shouldFailFinalGeneration {
            throw MockError.generationFailed
        }
        return finalAnswerResponse
    }
}

// MARK: - Classement déterministe (1.3)

/// Similarité identique pour tous les textes : le classement retombe alors
/// sur la seule position du moteur (`similarity * 0,7` est le même pour
/// tous), donc l'ordre de sortie est l'ordre d'entrée.
private struct ConstantSimilarityScorer: TextSimilarityScoring {
    let score: Double

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: score, count: candidates.count)
    }
}

/// Similarité fixée par texte, pour prouver qu'un classement a réellement
/// eu lieu (une source mieux notée remonte devant l'ordre du moteur).
private struct FixedSimilarityScorer: TextSimilarityScoring {
    let scoresByText: [String: Double]
    let defaultScore: Double

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        candidates.map { scoresByText[$0] ?? defaultScore }
    }
}

/// Rien n'est jamais un quasi-doublon. INDISPENSABLE ici : le vrai scorer
/// lexical fusionnerait des extraits de test comme « Contenu 1 » et
/// « Contenu 2 », qui ne diffèrent que d'un caractère.
private struct NeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Langue lue sur un préfixe conventionnel (« FR » / « EN »), indéterminée
/// sinon : rend la fusion par langue (décision 3) entièrement prévisible,
/// sans dépendre des modèles de langue du système.
private struct PrefixLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? {
        if text.hasPrefix("FR ") { return "fr" }
        if text.hasPrefix("EN ") { return "en" }
        return nil
    }
}

/// Classement qui conserve l'ordre du moteur : similarité constante, aucune
/// déduplication de contenu, aucune langue reconnue (un seul groupe).
private func orderPreservingRanker() -> SourceRanker {
    SourceRanker(
        relevanceScorer: ConstantSimilarityScorer(score: 0.5),
        duplicateScorer: NeverDuplicateScorer(),
        languageIdentifier: PrefixLanguageIdentifier()
    )
}

/// Orchestrateur de test. Mode Approfondi par défaut : ce sont les valeurs
/// historiques du pipeline (5 sources, jusqu'à 2 tours planner) que
/// vérifiaient les tests écrits avant 1.13 — le mode par défaut du produit
/// (Rapide) a ses propres tests. Classement déterministe par défaut, et
/// scraping factice : aucun test ne doit dépendre d'un modèle système ni du
/// réseau.
///
/// `widgets: []` par défaut (I1b) : la liste de production lancerait le VRAI
/// service météo (réseau Open-Meteo) dès qu'une classification demande la
/// météo. Les tests de widgets passent leurs propres widgets factices.
@MainActor
private func makeOrchestrator(
    failoverManager: FailoverManager,
    aiProvider: any AIGenerating,
    responseMode: ResponseMode = .deep,
    scrapeService: any ScrapeServing = MockScrapeService(succeeded: true),
    sourceRanker: SourceRanker = orderPreservingRanker(),
    writerComplexity: WriterPromptComplexity = .full,
    maxResultsUsedForContext: Int = 5,
    maxIterations: Int = 3,
    maxScrapedContextCharacters: Int = PromptTemplates.defaultMaxScrapedContextCharacters,
    widgets: [any SearchWidget] = []
) -> SearchOrchestrator {
    SearchOrchestrator(
        failoverManager: failoverManager,
        aiProvider: aiProvider,
        responseMode: responseMode,
        scrapeService: scrapeService,
        sourceRanker: sourceRanker,
        writerComplexity: writerComplexity,
        maxResultsUsedForContext: maxResultsUsedForContext,
        maxIterations: maxIterations,
        maxScrapedContextCharacters: maxScrapedContextCharacters,
        widgets: widgets
    )
}

// MARK: - Widgets factices (I1b)

/// Journal des widgets réellement exécutés : prouve qu'un widget non demandé
/// n'est jamais lancé (donc aucun appel LLM d'extraction).
private actor WidgetCallLog {
    private(set) var executedKinds: [SearchWidgetKind] = []

    func record(_ kind: SearchWidgetKind) {
        executedKinds.append(kind)
    }
}

/// Widget factice : se déclenche sur le même drapeau que le vrai widget de
/// son type, rend une sortie fixe (ou `nil`, « rien à afficher »), sans LLM
/// ni réseau.
private struct StubSearchWidget: SearchWidget {
    let kind: SearchWidgetKind
    let llmContext: String?
    let log: WidgetCallLog

    func shouldExecute(for classification: QueryClassification) -> Bool {
        switch kind {
        case .weather: classification.showWeatherWidget
        case .calculation: classification.showCalculationWidget
        }
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        await log.record(kind)
        guard let llmContext else { return nil }
        return SearchWidgetOutput(kind: kind, llmContext: llmContext)
    }
}

/// Services météo et calcul factices pour les VRAIS adaptateurs de
/// production (`WeatherSearchWidget`, `CalculationSearchWidget`) : comptent
/// leurs appels et ne rendent rien.
private actor ServiceCallCounter {
    private(set) var weatherCalls = 0
    private(set) var calculationCalls = 0

    func recordWeather() { weatherCalls += 1 }
    func recordCalculation() { calculationCalls += 1 }
}

private struct CountingWeatherService: WeatherWidgetServing {
    let counter: ServiceCallCounter

    func fetchWeather(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> WeatherWidgetResult? {
        await counter.recordWeather()
        return nil
    }
}

private struct CountingCalculationService: CalculationWidgetServing {
    let counter: ServiceCallCounter

    func computeCalculation(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> CalculationWidgetResult? {
        await counter.recordCalculation()
        return CalculationWidgetService.makeResult(forExpression: "15% * 240")
    }
}

@MainActor
@Suite("SearchOrchestrator")
struct SearchOrchestratorTests {
    private static func makeResult(title: String, url: String, content: String?) -> SearXNGSearchResult {
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

    private static let instance = URL(string: "https://searxng.example")!

    /// JSON de classification valide pour `QueryClassifier.parse` : tous les
    /// booléens à `false` sauf ceux passés à `true`.
    private static func classificationJSON(
        skipSearch: Bool = false,
        personalSearch: Bool = false,
        academicSearch: Bool = false,
        discussionSearch: Bool = false,
        showWeatherWidget: Bool = false,
        showStockWidget: Bool = false,
        showCalculationWidget: Bool = false,
        standaloneFollowUp: String
    ) -> String {
        """
        {"classification":{"skipSearch":\(skipSearch),"personalSearch":\(personalSearch),"academicSearch":\(academicSearch),\
        "discussionSearch":\(discussionSearch),"showWeatherWidget":\(showWeatherWidget),"showStockWidget":\(showStockWidget),\
        "showCalculationWidget":\(showCalculationWidget)},"standaloneFollowUp":"\(standaloneFollowUp)"}
        """
    }

    // MARK: - Cas nominal (pipeline complet : classification -> webSearch -> planner "done")

    @Test("Cas nominal : réponse et sources correspondent au mock, le prompt final contient la requête et le contexte")
    func happyPath() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "voici la réponse")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "quelle est la question ?")

        #expect(result.answer == "voici la réponse")
        #expect(result.sources == results)

        // Ordre garanti : classification -> 1 tour planner (fallback "done"
        // immédiat, `plannerResponses` vide) -> génération finale. Le prompt
        // final est donc toujours le DERNIER `generate()` reçu.
        let prompts = aiProvider.receivedPrompts
        #expect(prompts.count == 3)
        let finalPrompt = try #require(prompts.last)
        #expect(finalPrompt.contains("quelle est la question ?"))
        #expect(finalPrompt.contains("Titre A"))
        #expect(finalPrompt.contains("Contenu A"))
        #expect(finalPrompt.contains("Titre B"))
        #expect(finalPrompt.contains("Contenu B"))
    }

    @Test("Mode Approfondi : la limite de 5 sources restreint le contexte et les sources retournées")
    func defaultMaxResultsLimitsContextAndSources() async throws {
        let results = (1...7).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 5)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3", "Titre 4", "Titre 5"])

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(!finalPrompt.contains("Titre 6"))
        #expect(!finalPrompt.contains("Titre 7"))
    }

    @Test("Une limite personnalisée est honorée")
    func customMaxResultsIsHonored() async throws {
        let results = (1...4).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 2)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 2)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2"])
    }

    @Test("Zéro résultat de recherche : le provider IA est quand même appelé, sans crash")
    func zeroSearchResultsStillCallsAIProvider() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse sans contexte")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête sans résultat")

        #expect(result.answer == "réponse sans contexte")
        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("requête sans résultat"))
    }

    @Test("Un résultat sans contenu (nil) est géré sans crash")
    func resultWithoutContentDoesNotCrash() async throws {
        let results = [Self.makeResult(title: "Titre sans contenu", url: "https://sans-contenu.example", content: nil)]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources == results)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Titre sans contenu"))
    }

    @Test("Une erreur de FailoverManager remonte inchangée ; la classification a déjà eu lieu (1 appel), mais ni planner ni génération finale ne sont atteints")
    func failoverErrorPropagatesWithoutCallingAIProvider() async {
        let client = MockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await orchestrator.answer(query: "requête")
        }

        // Classification toujours appelée en premier, inconditionnellement
        // (voir `runResearch`) : c'est le seul appel qui a eu lieu avant que
        // l'action seedée (`WebSearchAction`) ne fasse échouer la recherche.
        let prompts = aiProvider.receivedPrompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("<user_query>"))
    }

    @Test("Une erreur du provider IA pendant la génération FINALE remonte inchangée, après une classification et un tour planner réussis")
    func aiProviderErrorPropagates() async {
        // Au moins une source : sans elle, aucun tour planner (bug 8).
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(shouldFailFinalGeneration: true)
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: MockError.generationFailed) {
            _ = try await orchestrator.answer(query: "requête")
        }
        #expect(aiProvider.receivedPrompts.filter { $0.contains("<planner_context>") }.count == 1)
    }

    @Test("Bug 3 : une erreur du planner (429, timeout, garde-fou) ne fait plus échouer la réponse — repli sur 'done', réponse produite avec les sources de la recherche")
    func plannerFailureFallsBackToDoneAndKeepsSources() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse malgré planner en échec", plannerError: MockError.generationFailed)
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.answer == "réponse malgré planner en échec")
        #expect(result.sources == results)
        // Classification + 1 tour planner (en échec, aucun 2e tour) + génération finale.
        #expect(aiProvider.receivedPrompts.count == 3)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[2] Titre B — https://b.example"))
    }

    @Test("Une erreur du provider IA PENDANT LA CLASSIFICATION (avant toute recherche) ne fait pas échouer tout le pipeline : repli sur la classification sûre (webSearch), la recherche et la génération continuent normalement")
    func classificationFailureFallsBackToWebSearchInsteadOfThrowing() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse malgré classification en échec", shouldFailClassification: true)
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        // AVANT le fix : ce throw de `queryClassifier.classify` (via
        // `aiProvider.generate`) remontait tel quel jusqu'ici, sans aucune
        // recherche ni réponse. APRÈS le fix : même repli "sûr" que pour une
        // sortie JSON imparsable (`QueryClassifier.parse`) -> `.webSearch`.
        let result = try await orchestrator.answer(query: "requête")

        #expect(result.answer == "réponse malgré classification en échec")
        #expect(result.sources.count == 1)
        let callCount = await client.callCount
        #expect(callCount == 1)
    }

    @Test("Une requête vide est transmise telle quelle (pas de validation à ce niveau) : le pipeline va quand même jusqu'au provider IA")
    func emptyQueryIsPassedThroughUnchanged() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse malgré requête vide")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "")

        #expect(result.answer == "réponse malgré requête vide")
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        // Dernière ligne du prompt de rédaction (`PromptTemplates`, .full).
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : "))
    }

    @Test("Une requête composée uniquement d'espaces est transmise telle quelle, sans normalisation")
    func whitespaceOnlyQueryIsPassedThroughUnchanged() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse malgré requête blanche")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "   ")

        #expect(result.answer == "réponse malgré requête blanche")
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : " + "   "))
    }

    @Test("maxResultsUsedForContext = 0 produit un contexte et des sources vides, sans crash")
    func zeroMaxResultsUsedForContextProducesEmptyContext() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse sans contexte")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 0)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(!finalPrompt.contains("Titre A"))
    }

    // MARK: - Routage de la classification (1.2)

    @Test("Classification .skip : aucune recherche lancée, sources/contexte vides, le provider IA génère quand même une réponse")
    func skipClassificationLaunchesNoSearch() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let skipJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "bonjour")
        let aiProvider = MockAIGenerating(classifyResponse: skipJSON, finalAnswerResponse: "salut !")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "Bonjour")

        #expect(result.answer == "salut !")
        #expect(result.sources.isEmpty)
        let callCount = await client.callCount
        #expect(callCount == 0)
        // `.skip` court-circuite AUSSI la boucle planner (pas seulement
        // l'action seedée) : seuls la classification et la génération finale
        // appellent le provider IA.
        let prompts = aiProvider.receivedPrompts
        #expect(prompts.count == 2)
    }

    @Test("Classification en échec : une salutation ne cherche pas sur le web, une question si (mission C1)")
    func failedClassificationSkipsSearchOnlyForGreetings() async throws {
        let greetingClient = MockSearXNGClient()
        let greetingProvider = MockAIGenerating(finalAnswerResponse: "Bonjour !", shouldFailClassification: true)
        let greetingOrchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: greetingClient, instances: [Self.instance]),
            aiProvider: greetingProvider,
            responseMode: .reliable
        )
        let greeting = try await greetingOrchestrator.answer(query: "Bonjour !")
        #expect(greeting.answer == "Bonjour !")
        #expect(await greetingClient.callCount == 0)

        let questionClient = MockSearXNGClient()
        let questionProvider = MockAIGenerating(shouldFailClassification: true)
        let questionOrchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: questionClient, instances: [Self.instance]),
            aiProvider: questionProvider
        )
        _ = try await questionOrchestrator.answer(query: "Quelle est la hauteur de la tour Eiffel ?")
        #expect(await questionClient.callCount > 0)
    }

    @Test("Classification academicSearch : AcademicSearchAction utilisée, moteurs arxiv/google scholar/pubmed forcés")
    func academicSearchRoutesToAcademicAction() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let academicJSON = Self.classificationJSON(academicSearch: true, standaloneFollowUp: "études sur X")
        let aiProvider = MockAIGenerating(classifyResponse: academicJSON)
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "études récentes sur X")

        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first?.engines == ["arxiv", "google scholar", "pubmed"])
    }

    @Test("Classification discussionSearch : SocialSearchAction utilisée, moteur reddit forcé")
    func discussionSearchRoutesToSocialAction() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let discussionJSON = Self.classificationJSON(discussionSearch: true, standaloneFollowUp: "avis sur Y")
        let aiProvider = MockAIGenerating(classifyResponse: discussionJSON)
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "avis des gens sur Y")

        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first?.engines == ["reddit"])
    }

    // MARK: - Bug 5 : moteurs forcés sans résultat

    /// `academic` vrai : arXiv/Scholar/PubMed ; faux : Reddit. Avant : un seul
    /// appel, réponse rédigée sans AUCUNE source.
    @Test("Bug 5 : moteurs forcés (Reddit, académique) sans résultat -> repli sur la recherche web, même requête reformulée, sources non vides", arguments: [true, false])
    func emptyForcedEngineSearchFallsBackToWebSearch(academic: Bool) async throws {
        let results = [Self.makeResult(title: "Titre web", url: "https://web.example", content: "Contenu web")]
        let client = MockSearXNGClient(
            response: SearXNGSearchResponse(results: results, suggestions: []),
            forcedEnginesResponse: SearXNGSearchResponse(results: [], suggestions: [])
        )
        let classification = academic
            ? Self.classificationJSON(academicSearch: true, standaloneFollowUp: "études sur X")
            : Self.classificationJSON(discussionSearch: true, standaloneFollowUp: "études sur X")
        let aiProvider = MockAIGenerating(classifyResponse: classification)
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "et pour X ?")

        #expect(result.sources == results)
        let forcedEngines = academic ? ["arxiv", "google scholar", "pubmed"] : ["reddit"]
        #expect(await client.receivedOptions == [SearXNGSearchOptions(engines: forcedEngines), SearXNGSearchOptions()])
        #expect(await client.receivedQueries == ["études sur X", "études sur X"])
    }

    @Test("Bug 5 : une recherche web par défaut sans résultat n'est PAS relancée — une vraie recherche vide reste valide")
    func emptyDefaultWebSearchIsNotRetried() async throws {
        let client = MockSearXNGClient()
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête sans résultat")

        #expect(result.sources.isEmpty)
        #expect(await client.callCount == 1)
    }

    @Test("Bug 5 : moteurs forcés AVEC résultats -> aucun repli, un seul appel")
    func forcedEngineSearchWithResultsKeepsThem() async throws {
        let redditResults = [Self.makeResult(title: "Fil Reddit", url: "https://reddit.example/r/x", content: "Avis")]
        let client = MockSearXNGClient(forcedEnginesResponse: SearXNGSearchResponse(results: redditResults, suggestions: []))
        let aiProvider = MockAIGenerating(classifyResponse: Self.classificationJSON(discussionSearch: true, standaloneFollowUp: "avis sur Y"))
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "avis des gens sur Y")

        #expect(result.sources == redditResults)
        #expect(await client.callCount == 1)
    }

    // MARK: - Widgets et bug 15 (I1b)

    /// Bug 15 — sur le code d'avant I1b, `primaryAction` valait
    /// `.calculationWidget` et `action(for:)` l'envoyait sur `WebSearchAction` :
    /// 1 appel SearXNG, un tour planner, et ce test levait (SearXNG en panne).
    @Test("Bug 15 : calcul pur (calcul + skipSearch) — aucun appel SearXNG ni planner, répond hors ligne, widget dans la réponse et le prompt")
    func pureCalculationNeverTouchesTheNetwork() async throws {
        let client = MockSearXNGClient(shouldFail: true)
        let log = WidgetCallLog()
        let calculationJSON = Self.classificationJSON(skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "15 % de 240")
        let aiProvider = MockAIGenerating(classifyResponse: calculationJSON, finalAnswerResponse: "36")
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .calculation, llmContext: "Résultat du calcul « 15% * 240 » : 36.", log: log)]
        )

        let result = try await orchestrator.answer(query: "Combien font 15 % de 240 ?")

        #expect(result.answer == "36")
        #expect(await client.callCount == 0)
        #expect(!aiProvider.receivedPrompts.contains { $0.contains("<planner_context>") })
        #expect(result.artifacts.widgets.map(\.kind) == [.calculation])
        #expect(result.artifacts.searchPerformed == false)
        #expect(result.artifacts.citableSourceCount == 0)
        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Aucune recherche web n'a été lancée"))
        #expect(finalPrompt.contains("<donnees_widgets>"))
        #expect(finalPrompt.contains("Résultat du calcul « 15% * 240 » : 36."))
        #expect(finalPrompt.hasSuffix("Combien font 15 % de 240 ?"))
    }

    @Test("Météo + skipSearch, widget abouti : aucune recherche web, la météo est dans la réponse et le prompt")
    func weatherAnsweredByWidgetSkipsSearch() async throws {
        let client = MockSearXNGClient()
        let log = WidgetCallLog()
        let weatherJSON = Self.classificationJSON(skipSearch: true, showWeatherWidget: true, standaloneFollowUp: "météo à Paris")
        let aiProvider = MockAIGenerating(classifyResponse: weatherJSON, finalAnswerResponse: "il fait beau")
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .weather, llmContext: "Météo à Paris : 21 °C, ensoleillé.", log: log)]
        )

        let result = try await orchestrator.answer(query: "Quel temps fait-il à Paris ?")

        #expect(result.answer == "il fait beau")
        #expect(await client.callCount == 0)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
        #expect(result.artifacts.searchPerformed == false)
        #expect(try #require(aiProvider.receivedPrompts.last).contains("Météo à Paris : 21 °C, ensoleillé."))
    }

    @Test("Météo + skipSearch, widget sans résultat (lieu introuvable, Open-Meteo injoignable) : repli sur UNE recherche web générale")
    func weatherWithoutWidgetResultFallsBackToWebSearch() async throws {
        let results = [Self.makeResult(title: "Météo Paris", url: "https://meteo.example", content: "21 °C")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let log = WidgetCallLog()
        let weatherJSON = Self.classificationJSON(skipSearch: true, showWeatherWidget: true, standaloneFollowUp: "météo à Paris")
        let aiProvider = MockAIGenerating(classifyResponse: weatherJSON)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .weather, llmContext: nil, log: log)]
        )

        let result = try await orchestrator.answer(query: "Quel temps fait-il à Paris ?")

        #expect(await log.executedKinds == [.weather])
        #expect(await client.callCount == 1)
        #expect(await client.receivedOptions == [SearXNGSearchOptions()])
        #expect(await client.receivedQueries == ["météo à Paris"])
        #expect(result.sources == results)
        #expect(result.artifacts.widgets.isEmpty)
        #expect(result.artifacts.searchPerformed)
    }

    @Test("Bourse + skipSearch : aucun widget bourse (hors champ), la recherche web reste lancée — donnée en direct")
    func stockWithSkipSearchStillSearchesTheWeb() async throws {
        let client = MockSearXNGClient()
        let stockJSON = Self.classificationJSON(skipSearch: true, showStockWidget: true, standaloneFollowUp: "cours de l'action Apple")
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockAIGenerating(classifyResponse: stockJSON)
        )

        _ = try await orchestrator.answer(query: "Combien vaut l'action Apple ?")

        #expect(await client.callCount == 1)
        #expect(await client.receivedOptions == [SearXNGSearchOptions()])
    }

    @Test("Météo sans skipSearch : recherche web ET widget, la météo s'ajoute aux sources dans le prompt")
    func weatherWithSearchRunsWidgetAndSearch() async throws {
        let results = [Self.makeResult(title: "Canicule", url: "https://actu.example", content: "Alerte canicule")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let log = WidgetCallLog()
        let weatherJSON = Self.classificationJSON(showWeatherWidget: true, standaloneFollowUp: "canicule à Paris")
        let aiProvider = MockAIGenerating(classifyResponse: weatherJSON)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .weather, llmContext: "Météo à Paris : 38 °C.", log: log)]
        )

        let result = try await orchestrator.answer(query: "La canicule à Paris va-t-elle durer ?")

        #expect(await client.callCount == 1)
        #expect(result.sources == results)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Alerte canicule"))
        #expect(finalPrompt.contains("Météo à Paris : 38 °C."))
    }

    /// Les VRAIS adaptateurs de production, branchés sur des services
    /// factices : la classification seule décide quel service est appelé.
    @Test("Aucun appel inutile : sans demande de la classification, ni extraction de lieu ni extraction d'expression")
    func widgetsRunOnlyWhenClassificationAsks() async throws {
        let counter = ServiceCallCounter()
        let widgets: [any SearchWidget] = [
            WeatherSearchWidget(service: CountingWeatherService(counter: counter)),
            CalculationSearchWidget(service: CountingCalculationService(counter: counter)),
        ]
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])

        let plain = makeOrchestrator(failoverManager: failoverManager, aiProvider: MockAIGenerating(), widgets: widgets)
        let plainResult = try await plain.answer(query: "Qui a écrit Germinal ?")
        #expect(await counter.weatherCalls == 0)
        #expect(await counter.calculationCalls == 0)
        #expect(plainResult.artifacts.widgets.isEmpty)

        let calculationJSON = Self.classificationJSON(skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "15 % de 240")
        let calculation = makeOrchestrator(failoverManager: failoverManager, aiProvider: MockAIGenerating(classifyResponse: calculationJSON), widgets: widgets)
        let calculationResult = try await calculation.answer(query: "Combien font 15 % de 240 ?")
        #expect(await counter.weatherCalls == 0)
        #expect(await counter.calculationCalls == 1)
        let data = try #require(calculationResult.artifacts.widgets.first?.calculationData)
        #expect(data.result == 36)
        #expect(calculationResult.artifacts.widgets.first?.weatherData == nil)
    }

    @Test("Liste de production : météo puis calcul, chacun sur son seul drapeau de classification")
    func productionWidgetListIsWeatherThenCalculation() {
        let widgets = SearchOrchestrator.defaultWidgets(aiProvider: MockAIGenerating())
        let weatherOnly = QueryClassification(
            skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: true, showStockWidget: false, showCalculationWidget: false, standaloneFollowUp: "météo"
        )
        let calculationOnly = QueryClassification(
            skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: true, showCalculationWidget: true, standaloneFollowUp: "calcul"
        )

        #expect(widgets.map(\.kind) == [.weather, .calculation])
        #expect(widgets.map { $0.shouldExecute(for: weatherOnly) } == [true, false])
        #expect(widgets.map { $0.shouldExecute(for: calculationOnly) } == [false, true])
    }

    @Test("Classification personalSearch SANS fichier joint : retombe sur une recherche web classique, sans crash")
    func personalSearchFallsBackToWebSearch() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let personalJSON = Self.classificationJSON(personalSearch: true, standaloneFollowUp: "résume mon document")
        let aiProvider = MockAIGenerating(classifyResponse: personalJSON)
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "résume le document que j'ai importé")

        let callCount = await client.callCount
        #expect(callCount == 1)
        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first == SearXNGSearchOptions())
    }

    // MARK: - Boucle planner (scrapeURL / done / bornage)

    @Test("Requête complexe : le planner déclenche scrapeURL avec 3 sources affichées puis done -> pages fusionnées dans leurs sources, sans document en plus")
    func plannerScrapesThenStops() async throws {
        let results = ["a", "b", "c", "d"].map { Self.makeResult(title: "Titre \($0.uppercased())", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let scrapeJSON = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example","https://c.example"]}
        """
        let doneJSON = """
        {"action":"done","urls":[]}
        """
        let aiProvider = MockAIGenerating(plannerResponses: [scrapeJSON, doneJSON], finalAnswerResponse: "réponse enrichie")
        let orchestrator = makeOrchestrator(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            scrapeService: MockScrapeService(succeeded: true)
        )

        let result = try await orchestrator.answer(query: "question complexe")

        #expect(result.answer == "réponse enrichie")
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu scrapé pour https://a.example"))
        #expect(finalPrompt.contains("Contenu scrapé pour https://b.example"))
        #expect(finalPrompt.contains("Contenu scrapé pour https://c.example"))
        #expect(!finalPrompt.contains("Contenu scrapé pour https://d.example"))
        // Invariant des citations : autant de documents que de sources.
        #expect(finalPrompt.contains("[4] Titre D"))
        #expect(!finalPrompt.contains("[5]"))
    }

    @Test("Un planner qui ne renvoie jamais 'done' est borné par maxIterations : pas de boucle infinie, nombre d'appels exact")
    func plannerNeverDoneStopsAtMaxIterations() async throws {
        // Une source différente par tour : avant le bug 11, ce test faisait
        // redemander la MÊME URL au 2e tour, téléchargée deux fois sans que
        // rien ne le signale ; ce cas arrête désormais la boucle (voir
        // SearchOrchestratorStreamingTests, bug 11).
        let results = (1...3).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let failoverManager = FailoverManager(client: MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: [])), instances: [Self.instance])
        let aiProvider = MockAIGenerating(plannerResponses: [
            #"{"action":"scrapeURL","urls":["https://1.example"]}"#,
            #"{"action":"scrapeURL","urls":["https://2.example"]}"#,
        ])
        let orchestrator = makeOrchestrator(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            scrapeService: MockScrapeService(succeeded: true),
            maxIterations: 3
        )

        _ = try await orchestrator.answer(query: "question")

        // 1 classification + 2 tours planner (itérations 2 et 3, bornées par
        // `maxIterations = 3`, plage `2...maxIterations`) + 1 génération
        // finale = 4 prompts exactement : la boucle s'arrête d'elle-même à
        // la fin de la plage, sans jamais recevoir "done".
        let prompts = aiProvider.receivedPrompts
        #expect(prompts.count == 4)
        let finalPrompt = try #require(prompts.last)
        #expect(finalPrompt.contains("Contenu scrapé pour https://1.example"))
        #expect(finalPrompt.contains("Contenu scrapé pour https://2.example"))
    }

    @Test("Sortie planner non-JSON : traitée comme 'done', jamais de throw ni de blocage")
    func plannerUnparseableOutputFallsBackToDone() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let failoverManager = FailoverManager(client: MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: [])), instances: [Self.instance])
        let aiProvider = MockAIGenerating(plannerResponses: ["ceci n'est pas du JSON"], finalAnswerResponse: "réponse malgré planner imparsable")
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "question")

        #expect(result.answer == "réponse malgré planner imparsable")
        // 1 classification + 1 seul tour planner (fallback "done" immédiat,
        // sortie imparsable) + 1 génération finale.
        let prompts = aiProvider.receivedPrompts
        #expect(prompts.count == 3)
    }

    @Test("decideNextAction : JSON valide avec action scrapeURL est parsé correctement ; une clé 'reasoning' (plus demandée) est tolérée")
    func decideNextActionParsesValidScrapeURLJSON() {
        let raw = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example"],"reasoning":"pour approfondir"}
        """
        let decision = SearchOrchestrator.decideNextAction(rawOutput: raw)

        #expect(decision == PlannerDecision(actionName: "scrapeURL", urls: ["https://a.example", "https://b.example"]))
    }

    @Test("decideNextAction : sortie totalement invalide retombe sur 'done'")
    func decideNextActionFallsBackToDoneOnInvalidOutput() {
        let decision = SearchOrchestrator.decideNextAction(rawOutput: "n'importe quoi, pas du JSON")

        #expect(decision.actionName == "done")
        #expect(decision.urls.isEmpty)
    }

    // MARK: - Classement (1.3) et prompt de rédaction (1.4)

    @Test("Le classement remplace le simple prefix : la source la mieux notée passe en tête, et son rang devient son numéro de citation")
    func rankingReordersSourcesAndCitationNumbers() async throws {
        let results = (1...4).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockAIGenerating()
        let ranker = SourceRanker(
            relevanceScorer: FixedSimilarityScorer(scoresByText: ["Contenu 3": 0.95], defaultScore: 0.3),
            duplicateScorer: NeverDuplicateScorer(),
            languageIdentifier: PrefixLanguageIdentifier()
        )
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            sourceRanker: ranker
        )

        let result = try await orchestrator.answer(query: "requête")

        // (0,95*0,7 + 0,8*0,3) = 0,905 pour le 3e, contre 0,51 au mieux pour
        // les autres : il passe devant, les autres gardent l'ordre du moteur.
        #expect(result.sources.map(\.title) == ["Titre 3", "Titre 1", "Titre 2", "Titre 4"])
        // Invariant des citations : `[n]` du prompt == `sources[n - 1]`.
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[1] Titre 3 — https://3.example"))
        #expect(finalPrompt.contains("[2] Titre 1 — https://1.example"))
    }

    @Test("Décision 3 dans le pipeline : chaque langue est classée à part puis les meilleures sont alternées")
    func pipelineInterleavesLanguages() async throws {
        let french = (1...4).map { Self.makeResult(title: "Article \($0)", url: "https://fr\($0).example", content: "FR contenu \($0)") }
        let english = Self.makeResult(title: "Article EN", url: "https://en.example", content: "EN content")
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: french + [english], suggestions: []))
        // Le biais mesuré : la langue de la requête marque plus haut que le
        // sens. Classé d'un bloc, l'extrait anglais finirait dernier.
        let scores = ["FR contenu 1": 0.9, "FR contenu 2": 0.9, "FR contenu 3": 0.9, "FR contenu 4": 0.9, "EN content": 0.5]
        let ranker = SourceRanker(
            relevanceScorer: FixedSimilarityScorer(scoresByText: scores, defaultScore: 0),
            duplicateScorer: NeverDuplicateScorer(),
            languageIdentifier: PrefixLanguageIdentifier()
        )
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockAIGenerating(),
            responseMode: .quick,
            sourceRanker: ranker
        )

        let result = try await orchestrator.answer(query: "FR question en français")

        #expect(result.sources.map(\.url) == ["https://fr1.example", "https://en.example", "https://fr2.example"])
    }

    @Test("Le prompt final est le prompt de rédaction : citations [n], consignes du mode, contexte numéroté")
    func finalPromptIsTheWriterPrompt() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "question")

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("### Citations"))
        #expect(finalPrompt.contains("mode Approfondi"))
        #expect(finalPrompt.contains("[1] Titre A — https://a.example\nExtrait : Contenu A"))
        // Une formulation bannie est listée dans les consignes (interpolée
        // depuis la source de vérité unique de `PromptTemplates`).
        let bannedPhrase = try #require(PromptTemplates.bannedFillerPhrases.first)
        #expect(finalPrompt.contains(bannedPhrase))
    }

    @Test("writerComplexity .concise : le prompt court destiné aux petits modèles est utilisé")
    func conciseWriterComplexityIsForwarded() async throws {
        let client = MockSearXNGClient()
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            writerComplexity: .concise
        )

        _ = try await orchestrator.answer(query: "question")

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.hasPrefix("Tu es Triva. Réponds à la question en t'appuyant uniquement sur les sources numérotées"))
        #expect(!finalPrompt.contains("### Principes fondamentaux"))
    }

    @Test("L'historique de conversation est transmis au prompt de rédaction")
    func chatHistoryReachesWriterPrompt() async throws {
        let aiProvider = MockAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: MockSearXNGClient(), instances: [Self.instance]), aiProvider: aiProvider)
        let history = [
            ClassifierChatMessage(role: .user, content: "Qui dirige Apple ?"),
            ClassifierChatMessage(role: .assistant, content: "Tim Cook[1]."),
        ]

        _ = try await orchestrator.answer(query: "Et son salaire ?", chatHistory: history)

        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Utilisateur : Qui dirige Apple ?"))
        #expect(finalPrompt.contains("Assistant : Tim Cook[1]."))
    }

    @Test("Protection anti-overflow niveau 2 conservée : le budget de contenu scrapé est partagé entre les documents")
    func scrapedContextBudgetIsSharedAcrossDocuments() async throws {
        // Deux sources AFFICHÉES : depuis le bug 8, une URL hors des sources
        // n'est plus scrapée, et le budget ne serait plus partagé du tout.
        let results = ["a", "b"].map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let scrapeJSON = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example"],"reasoning":"approfondir"}
        """
        let aiProvider = MockAIGenerating(plannerResponses: [scrapeJSON])
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            maxScrapedContextCharacters: 20
        )

        _ = try await orchestrator.answer(query: "question")

        // 2 documents portent du contenu scrapé -> 10 caractères chacun
        // (« Contenu sc ») ; un seul document en aurait reçu 20.
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu de la page : Contenu sc"))
        #expect(!finalPrompt.contains("Contenu de la page : Contenu scr"))
        #expect(!finalPrompt.contains("Contenu scrapé pour https://a.example"))
        #expect(!finalPrompt.contains("Contenu scrapé pour https://b.example"))
    }

    @Test("effectiveLimit : le plus petit du plafond et de la valeur du mode, jamais négatif", arguments: [
        (cap: 5, modeValue: 3, expected: 3),
        (cap: 2, modeValue: 5, expected: 2),
        (cap: 5, modeValue: 5, expected: 5),
        (cap: 0, modeValue: 5, expected: 0),
        (cap: -1, modeValue: 5, expected: 0),
    ])
    func effectiveLimitIsTheSmallerBound(cap: Int, modeValue: Int, expected: Int) {
        #expect(SearchOrchestrator.effectiveLimit(cap: cap, modeValue: modeValue) == expected)
    }
}

// MARK: - Routage, prompt des widgets, suggestions, planner (I1b) — fonctions pures

extension SearchOrchestratorTests {
    /// `nonisolated` : appelée depuis les arguments d'un test paramétré,
    /// évalués hors du main actor.
    private nonisolated static func classification(
        skip: Bool = false,
        personal: Bool = false,
        academic: Bool = false,
        discussion: Bool = false,
        weather: Bool = false,
        stock: Bool = false,
        calculation: Bool = false
    ) -> QueryClassification {
        QueryClassification(
            skipSearch: skip,
            personalSearch: personal,
            academicSearch: academic,
            discussionSearch: discussion,
            showWeatherWidget: weather,
            showStockWidget: stock,
            showCalculationWidget: calculation,
            standaloneFollowUp: "question"
        )
    }

    /// Les lignes « calcul + skip » et « météo + skip » sont celles du bug
    /// 15 : `primaryAction` les résumait en widget, l'ancien `action(for:)` en
    /// recherche web.
    @Test("SearchRoute.resolve : la classification COMPLÈTE décide, pas primaryAction", arguments: [
        (classification(), false, SearchRoute.web(.general)),
        (classification(skip: true), false, SearchRoute.none),
        (classification(skip: true, calculation: true), false, SearchRoute.none),
        (classification(calculation: true), false, SearchRoute.web(.general)),
        (classification(skip: true, weather: true), false, SearchRoute.webUnlessWeatherAnswered),
        (classification(skip: true, weather: true, calculation: true), false, SearchRoute.webUnlessWeatherAnswered),
        (classification(weather: true), false, SearchRoute.web(.general)),
        (classification(skip: true, stock: true), false, SearchRoute.web(.general)),
        (classification(academic: true), false, SearchRoute.web(.academic)),
        (classification(discussion: true), false, SearchRoute.web(.discussion)),
        (classification(skip: true, academic: true), false, SearchRoute.none),
        (classification(personal: true), false, SearchRoute.web(.general)),
        (classification(personal: true), true, SearchRoute.attachments),
        (classification(skip: true, personal: true), true, SearchRoute.attachments),
        (classification(academic: true), true, SearchRoute.web(.academic)),
    ])
    func routeFollowsTheFullClassification(classification: QueryClassification, hasAttachments: Bool, expected: SearchRoute) {
        #expect(SearchRoute.resolve(for: classification, hasAttachments: hasAttachments) == expected)
    }

    @Test("Widgets dans le prompt : juste avant le bloc de la question, après la date, dans les QUATRE gabarits", arguments: [
        (true, WriterPromptComplexity.full),
        (true, WriterPromptComplexity.concise),
        (false, WriterPromptComplexity.full),
        (false, WriterPromptComplexity.concise),
    ])
    func widgetContextSitsRightBeforeTheQuestion(searchPerformed: Bool, complexity: WriterPromptComplexity) throws {
        let query = "Ligne 1 de la question\n\nLigne 2 de la question"
        let prompt = SearchOrchestrator.buildPrompt(
            query: query,
            standaloneQuery: "Question reformulée autonome",
            sources: [Self.makeResult(title: "Titre", url: "https://a.example", content: "Extrait")],
            mode: .deep,
            complexity: complexity,
            searchPerformed: searchPerformed,
            widgetContext: "Résultat du calcul « 2 + 2 » : 4."
        )

        let block = try #require(prompt.range(of: "<donnees_widgets>"))
        let dateLine = try #require(prompt.range(of: "(UTC", options: .backwards))
        let reformulation = try #require(prompt.range(of: "Question reformulée d'après la conversation", options: .backwards))
        #expect(dateLine.upperBound < block.lowerBound)
        #expect(block.upperBound < reformulation.lowerBound)
        #expect(prompt.components(separatedBy: "<donnees_widgets>").count == 2)
        #expect(prompt.contains(SearchOrchestrator.widgetContextInstruction))
        #expect(prompt.contains("Résultat du calcul « 2 + 2 » : 4.\n</donnees_widgets>\n\nQuestion reformulée"))
        #expect(prompt.hasSuffix(query))
    }

    @Test("Widgets dans le prompt : contexte vide -> prompt inchangé ; gabarit sans la question en fin -> bloc ajouté à la fin, jamais perdu")
    func widgetContextEdgeCases() {
        let prompt = "Consignes.\n\nQuestion : combien ?"

        #expect(SearchOrchestrator.insertingWidgetContext("  \n ", into: prompt, query: "combien ?") == prompt)
        let fallback = SearchOrchestrator.insertingWidgetContext("Donnée.", into: prompt, query: "autre question")
        #expect(fallback.hasPrefix(prompt + "\n\n<donnees_widgets>"))
        #expect(fallback.hasSuffix("Donnée.\n</donnees_widgets>"))
    }

    @Test("suggestionsHistory : tours précédents, question, puis la réponse telle que lue — sans <think> ni <tldr>")
    func suggestionsHistoryStripsReasoningBlocks() {
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: MockSearXNGClient(), instances: [Self.instance]), aiProvider: MockAIGenerating())
        let previous = [
            ClassifierChatMessage(role: .user, content: "Q1"),
            ClassifierChatMessage(role: .assistant, content: "R1"),
        ]

        let history = orchestrator.suggestionsHistory(
            previousTurns: previous,
            query: "Q2",
            answer: "<think>Je pèse les sources.</think>\n<tldr>Résumé en une phrase.</tldr>\n\nCorps de la réponse[1]."
        )

        #expect(history.map(\.content) == ["Q1", "R1", "Q2", "Corps de la réponse[1]."])
        #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("suggestionsHistory : bornée comme l'historique du classifieur (préréglage Apple Intelligence : 4 messages de 600 caractères)")
    func suggestionsHistoryIsBounded() {
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: MockSearXNGClient(), instances: [Self.instance]),
            aiProvider: MockAIGenerating(),
            configuration: .appleIntelligence,
            widgets: []
        )
        let previous = (1...3).flatMap { turn in
            [ClassifierChatMessage(role: .user, content: "Q\(turn)"), ClassifierChatMessage(role: .assistant, content: "R\(turn)")]
        }
        let longAnswer = String(repeating: "La photosynthèse produit du glucose. ", count: 40)

        let history = orchestrator.suggestionsHistory(previousTurns: previous, query: "Q4", answer: longAnswer)

        #expect(history.count == 4)
        #expect(history.map(\.content).prefix(3) == ["Q3", "R3", "Q4"])
        let answer = history.last?.content ?? ""
        #expect(answer.hasSuffix("[…]"))
        #expect(answer.count <= 600 + " […]".count)
    }

    @Test("plannerActionNames : seulement les actions qui ont encore un objet, done toujours ; sans fichier joint, exactement l'ancienne liste")
    func plannerActionNamesFollowWhatIsLeft() {
        #expect(SearchOrchestrator.plannerActionNames(canScrape: true, canSearchUploads: false) == ["scrapeURL", "done"])
        #expect(SearchOrchestrator.plannerActionNames(canScrape: true, canSearchUploads: true) == ["scrapeURL", "uploadsSearch", "done"])
        #expect(SearchOrchestrator.plannerActionNames(canScrape: false, canSearchUploads: true) == ["uploadsSearch", "done"])
        #expect(SearchOrchestrator.plannerActionNames(canScrape: false, canSearchUploads: false) == ["done"])
    }

    @Test("plannerPrompt : uploadsSearch et son champ queries n'apparaissent qu'avec des fichiers joints ; sinon le texte d'avant 1.11")
    func plannerPromptOffersUploadsSearchOnlyWhenAvailable() {
        let sources = [Self.makeResult(title: "T", url: "https://a.example", content: nil)]

        let withoutUploads = SearchOrchestrator.plannerPrompt(
            query: "q", displayedSources: sources, availableActionNames: ["scrapeURL", "done"], iteration: 2, maxIterations: 3
        )
        let withUploads = SearchOrchestrator.plannerPrompt(
            query: "q", displayedSources: sources, availableActionNames: ["scrapeURL", "uploadsSearch", "done"], iteration: 2, maxIterations: 3
        )
        // Toutes les sources déjà tentées : il ne reste que les fichiers joints.
        let uploadsOnly = SearchOrchestrator.plannerPrompt(
            query: "q", displayedSources: sources, availableActionNames: ["uploadsSearch", "done"], iteration: 3, maxIterations: 3
        )

        #expect(!withoutUploads.contains("uploadsSearch"))
        #expect(!withoutUploads.contains("\"queries\""))
        #expect(withoutUploads.contains("\"action\": \"scrapeURL\" ou \"done\",\n  \"urls\": [\"url1\", \"url2\"]\n}"))
        #expect(withUploads.contains("- \"uploadsSearch\" : cherche dans les fichiers joints"))
        #expect(withUploads.contains("\"action\": \"scrapeURL\", \"uploadsSearch\" ou \"done\",\n  \"urls\": [\"url1\", \"url2\"],\n  \"queries\": [\"requête 1\"]\n}"))
        #expect(uploadsOnly.contains("\"action\": \"uploadsSearch\" ou \"done\",\n  \"queries\": [\"requête 1\"]\n}"))
        #expect(!uploadsOnly.contains("\"urls\""))
        #expect(!uploadsOnly.contains("- \"scrapeURL\""))
    }

    @Test("decideNextAction : lit les requêtes de uploadsSearch ; absentes, liste vide")
    func decideNextActionReadsQueries() {
        let uploads = SearchOrchestrator.decideNextAction(rawOutput: #"{"action":"uploadsSearch","queries":["clause de résiliation","préavis"]}"#)
        let scrape = SearchOrchestrator.decideNextAction(rawOutput: #"{"action":"scrapeURL","urls":["https://a.example"]}"#)

        #expect(uploads == PlannerDecision(actionName: "uploadsSearch", urls: [], queries: ["clause de résiliation", "préavis"]))
        #expect(scrape == PlannerDecision(actionName: "scrapeURL", urls: ["https://a.example"]))
    }
}
