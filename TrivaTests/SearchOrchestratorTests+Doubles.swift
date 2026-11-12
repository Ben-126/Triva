//
//  SearchOrchestratorTests+Doubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Doublures et fabriques des suites `SearchOrchestratorTests` (découpage E1b : partagées par
/// les fichiers `SearchOrchestrator*Tests.swift`). Noms préfixés `Pipeline` là où un nom identique existe
/// ailleurs dans la cible de test, maintenant que ces types ne sont plus `private` à un fichier.

enum PipelineMockError: Error, Sendable, Equatable {
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
actor PipelineMockSearXNGClient {
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
}

extension PipelineMockSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        receivedOptions.append(options)
        receivedQueries.append(query)
        if shouldFail {
            throw PipelineMockError.searchFailed
        }
        if let forcedEnginesResponse, !options.engines.isEmpty {
            return forcedEnginesResponse
        }
        return response
    }
}

/// `ScrapeServing` factice à réponse fixe, pour tester la boucle planner
/// (`scrapeURL`) sans réseau réel.
struct PipelineMockScrapeService: ScrapeServing {
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
final class PipelineMockAIGenerating: AIGenerating {
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
                throw PipelineMockError.generationFailed
            }
            return classifyResponse
        }
        if prompt.contains("<planner_context>") {
            if let plannerError { throw plannerError }
            return plannerResponses.isEmpty ? "" : plannerResponses.removeFirst()
        }
        if shouldFailFinalGeneration {
            throw PipelineMockError.generationFailed
        }
        return finalAnswerResponse
    }
}

// MARK: - Classement déterministe (1.3)

/// Similarité identique pour tous les textes : le classement retombe alors
/// sur la seule position du moteur (`similarity * 0,7` est le même pour
/// tous), donc l'ordre de sortie est l'ordre d'entrée.
struct PipelineConstantSimilarityScorer: TextSimilarityScoring {
    let score: Double

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: score, count: candidates.count)
    }
}

/// Similarité fixée par texte, pour prouver qu'un classement a réellement
/// eu lieu (une source mieux notée remonte devant l'ordre du moteur).
struct PipelineFixedSimilarityScorer: TextSimilarityScoring {
    let scoresByText: [String: Double]
    let defaultScore: Double

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        candidates.map { scoresByText[$0] ?? defaultScore }
    }
}

/// Rien n'est jamais un quasi-doublon. INDISPENSABLE ici : le vrai scorer
/// lexical fusionnerait des extraits de test comme « Contenu 1 » et
/// « Contenu 2 », qui ne diffèrent que d'un caractère.
struct PipelineNeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Langue lue sur un préfixe conventionnel (« FR » / « EN »), indéterminée
/// sinon : rend la fusion par langue (décision 3) entièrement prévisible,
/// sans dépendre des modèles de langue du système.
struct PipelinePrefixLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? {
        if text.hasPrefix("FR ") { return "fr" }
        if text.hasPrefix("EN ") { return "en" }
        return nil
    }
}

/// Classement qui conserve l'ordre du moteur : similarité constante, aucune
/// déduplication de contenu, aucune langue reconnue (un seul groupe).
func pipelineOrderPreservingRanker() -> SourceRanker {
    SourceRanker(
        relevanceScorer: PipelineConstantSimilarityScorer(score: 0.5),
        duplicateScorer: PipelineNeverDuplicateScorer(),
        languageIdentifier: PipelinePrefixLanguageIdentifier()
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
func makePipelineOrchestrator(
    failoverManager: FailoverManager,
    aiProvider: any AIGenerating,
    responseMode: ResponseMode = .deep,
    scrapeService: any ScrapeServing = PipelineMockScrapeService(succeeded: true),
    sourceRanker: SourceRanker = pipelineOrderPreservingRanker(),
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
actor WidgetCallLog {
    private(set) var executedKinds: [SearchWidgetKind] = []

    func record(_ kind: SearchWidgetKind) {
        executedKinds.append(kind)
    }
}

/// Widget factice : se déclenche sur le même drapeau que le vrai widget de
/// son type, rend une sortie fixe (ou `nil`, « rien à afficher »), sans LLM
/// ni réseau.
struct StubSearchWidget: SearchWidget {
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
actor ServiceCallCounter {
    private(set) var weatherCalls = 0
    private(set) var calculationCalls = 0

    func recordWeather() { weatherCalls += 1 }
    func recordCalculation() { calculationCalls += 1 }
}

struct CountingWeatherService: WeatherWidgetServing {
    let counter: ServiceCallCounter

    func fetchWeather(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> WeatherWidgetResult? {
        await counter.recordWeather()
        return nil
    }
}

struct CountingCalculationService: CalculationWidgetServing {
    let counter: ServiceCallCounter

    func computeCalculation(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> CalculationWidgetResult? {
        await counter.recordCalculation()
        return CalculationWidgetService.makeResult(forExpression: "15% * 240")
    }
}
