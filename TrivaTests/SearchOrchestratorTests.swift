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
/// aucun appel.
private actor MockSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private let shouldFail: Bool
    private(set) var receivedOptions: [SearXNGSearchOptions] = []
    private(set) var callCount = 0

    init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []), shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        receivedOptions.append(options)
        if shouldFail {
            throw MockError.searchFailed
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
private final class MockAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let classifyResponse: String
    private var plannerResponses: [String]
    private let finalAnswerResponse: String
    private let shouldFailFinalGeneration: Bool
    private let shouldFailClassification: Bool

    init(
        classifyResponse: String = "",
        plannerResponses: [String] = [],
        finalAnswerResponse: String = "réponse factice",
        shouldFailFinalGeneration: Bool = false,
        shouldFailClassification: Bool = false
    ) {
        self.classifyResponse = classifyResponse
        self.plannerResponses = plannerResponses
        self.finalAnswerResponse = finalAnswerResponse
        self.shouldFailFinalGeneration = shouldFailFinalGeneration
        self.shouldFailClassification = shouldFailClassification
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
            return plannerResponses.isEmpty ? "" : plannerResponses.removeFirst()
        }
        if shouldFailFinalGeneration {
            throw MockError.generationFailed
        }
        return finalAnswerResponse
    }
}

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
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "quelle est la question ?")

        #expect(result.answer == "voici la réponse")
        #expect(result.sources == results)

        // Ordre garanti : classification -> 1 tour planner (fallback "done"
        // immédiat, `plannerResponses` vide) -> génération finale. Le prompt
        // final est donc toujours le DERNIER `generate()` reçu.
        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 3)
        let finalPrompt = try #require(prompts.last)
        #expect(finalPrompt.contains("quelle est la question ?"))
        #expect(finalPrompt.contains("Titre A"))
        #expect(finalPrompt.contains("Contenu A"))
        #expect(finalPrompt.contains("Titre B"))
        #expect(finalPrompt.contains("Contenu B"))
    }

    @Test("La limite par défaut (5) restreint le contexte et les sources retournées")
    func defaultMaxResultsLimitsContextAndSources() async throws {
        let results = (1...7).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 5)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3", "Titre 4", "Titre 5"])

        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(!finalPrompt.contains("Titre 6"))
        #expect(!finalPrompt.contains("Titre 7"))
    }

    @Test("Une limite personnalisée est honorée")
    func customMaxResultsIsHonored() async throws {
        let results = (1...4).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 2)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 2)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2"])
    }

    @Test("Zéro résultat de recherche : le provider IA est quand même appelé, sans crash")
    func zeroSearchResultsStillCallsAIProvider() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse sans contexte")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête sans résultat")

        #expect(result.answer == "réponse sans contexte")
        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("requête sans résultat"))
    }

    @Test("Un résultat sans contenu (nil) est géré sans crash")
    func resultWithoutContentDoesNotCrash() async throws {
        let results = [Self.makeResult(title: "Titre sans contenu", url: "https://sans-contenu.example", content: nil)]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources == results)
        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Titre sans contenu"))
    }

    @Test("Une erreur de FailoverManager remonte inchangée ; la classification a déjà eu lieu (1 appel), mais ni planner ni génération finale ne sont atteints")
    func failoverErrorPropagatesWithoutCallingAIProvider() async {
        let client = MockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating()
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await orchestrator.answer(query: "requête")
        }

        // Classification toujours appelée en premier, inconditionnellement
        // (voir `runResearch`) : c'est le seul appel qui a eu lieu avant que
        // l'action seedée (`WebSearchAction`) ne fasse échouer la recherche.
        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("<user_query>"))
    }

    @Test("Une erreur du provider IA pendant la génération FINALE remonte inchangée, après une classification et un tour planner réussis")
    func aiProviderErrorPropagates() async {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(shouldFailFinalGeneration: true)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: MockError.generationFailed) {
            _ = try await orchestrator.answer(query: "requête")
        }
    }

    @Test("Une erreur du provider IA PENDANT LA CLASSIFICATION (avant toute recherche) ne fait pas échouer tout le pipeline : repli sur la classification sûre (webSearch), la recherche et la génération continuent normalement")
    func classificationFailureFallsBackToWebSearchInsteadOfThrowing() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse malgré classification en échec", shouldFailClassification: true)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "")

        #expect(result.answer == "réponse malgré requête vide")
        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(finalPrompt.hasSuffix("Question : "))
    }

    @Test("Une requête composée uniquement d'espaces est transmise telle quelle, sans normalisation")
    func whitespaceOnlyQueryIsPassedThroughUnchanged() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse malgré requête blanche")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "   ")

        #expect(result.answer == "réponse malgré requête blanche")
        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(finalPrompt.hasSuffix("Question : " + "   "))
    }

    @Test("maxResultsUsedForContext = 0 produit un contexte et des sources vides, sans crash")
    func zeroMaxResultsUsedForContextProducesEmptyContext() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockAIGenerating(finalAnswerResponse: "réponse sans contexte")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 0)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(!finalPrompt.contains("Titre A"))
    }

    // MARK: - Routage de la classification (1.2)

    @Test("Classification .skip : aucune recherche lancée, sources/contexte vides, le provider IA génère quand même une réponse")
    func skipClassificationLaunchesNoSearch() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let skipJSON = """
        {
          "classification": {
            "skipSearch": true,
            "personalSearch": false,
            "academicSearch": false,
            "discussionSearch": false,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "bonjour"
        }
        """
        let aiProvider = MockAIGenerating(classifyResponse: skipJSON, finalAnswerResponse: "salut !")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "Bonjour")

        #expect(result.answer == "salut !")
        #expect(result.sources.isEmpty)
        let callCount = await client.callCount
        #expect(callCount == 0)
        // `.skip` court-circuite AUSSI la boucle planner (pas seulement
        // l'action seedée) : seuls la classification et la génération finale
        // appellent le provider IA.
        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 2)
    }

    @Test("Classification academicSearch : AcademicSearchAction utilisée, moteurs arxiv/google scholar/pubmed forcés")
    func academicSearchRoutesToAcademicAction() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let academicJSON = """
        {
          "classification": {
            "skipSearch": false,
            "personalSearch": false,
            "academicSearch": true,
            "discussionSearch": false,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "études sur X"
        }
        """
        let aiProvider = MockAIGenerating(classifyResponse: academicJSON)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "études récentes sur X")

        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first?.engines == ["arxiv", "google scholar", "pubmed"])
    }

    @Test("Classification discussionSearch : SocialSearchAction utilisée, moteur reddit forcé")
    func discussionSearchRoutesToSocialAction() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let discussionJSON = """
        {
          "classification": {
            "skipSearch": false,
            "personalSearch": false,
            "academicSearch": false,
            "discussionSearch": true,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "avis sur Y"
        }
        """
        let aiProvider = MockAIGenerating(classifyResponse: discussionJSON)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "avis des gens sur Y")

        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first?.engines == ["reddit"])
    }

    @Test("Classification showWeatherWidget (widget pas encore implémenté, 1.5) : retombe sur une recherche web classique, sans crash")
    func widgetClassificationFallsBackToWebSearch() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let weatherJSON = """
        {
          "classification": {
            "skipSearch": false,
            "personalSearch": false,
            "academicSearch": false,
            "discussionSearch": false,
            "showWeatherWidget": true,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "météo à Paris"
        }
        """
        let aiProvider = MockAIGenerating(classifyResponse: weatherJSON, finalAnswerResponse: "il fait beau")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "Quel temps fait-il à Paris ?")

        #expect(result.answer == "il fait beau")
        let callCount = await client.callCount
        #expect(callCount == 1)
        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first == SearXNGSearchOptions())
    }

    @Test("Classification personalSearch (aucun stockage de document côté app) : retombe sur une recherche web classique, sans crash")
    func personalSearchFallsBackToWebSearch() async throws {
        let client = MockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let personalJSON = """
        {
          "classification": {
            "skipSearch": false,
            "personalSearch": true,
            "academicSearch": false,
            "discussionSearch": false,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "résume mon document"
        }
        """
        let aiProvider = MockAIGenerating(classifyResponse: personalJSON)
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "résume le document que j'ai importé")

        let callCount = await client.callCount
        #expect(callCount == 1)
        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first == SearXNGSearchOptions())
    }

    // MARK: - Boucle planner (scrapeURL / done / bornage)

    @Test("Requête complexe : le planner déclenche scrapeURL avec 3 URLs puis done -> scrapedPages accumulées, contenu présent dans le prompt final")
    func plannerScrapesThenStops() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let scrapeJSON = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example","https://c.example"],"reasoning":"approfondir"}
        """
        let doneJSON = """
        {"action":"done","urls":[],"reasoning":"assez de contenu"}
        """
        let aiProvider = MockAIGenerating(plannerResponses: [scrapeJSON, doneJSON], finalAnswerResponse: "réponse enrichie")
        let orchestrator = SearchOrchestrator(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            scrapeService: MockScrapeService(succeeded: true)
        )

        let result = try await orchestrator.answer(query: "question complexe")

        #expect(result.answer == "réponse enrichie")
        let finalPrompt = try #require(await aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu scrapé pour https://a.example"))
        #expect(finalPrompt.contains("Contenu scrapé pour https://b.example"))
        #expect(finalPrompt.contains("Contenu scrapé pour https://c.example"))
    }

    @Test("Un planner qui ne renvoie jamais 'done' est borné par maxIterations : pas de boucle infinie, nombre d'appels exact")
    func plannerNeverDoneStopsAtMaxIterations() async throws {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let scrapeJSON = """
        {"action":"scrapeURL","urls":["https://a.example"],"reasoning":"encore"}
        """
        let aiProvider = MockAIGenerating(plannerResponses: [scrapeJSON, scrapeJSON])
        let orchestrator = SearchOrchestrator(
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
        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 4)
    }

    @Test("Sortie planner non-JSON : traitée comme 'done', jamais de throw ni de blocage")
    func plannerUnparseableOutputFallsBackToDone() async throws {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockAIGenerating(plannerResponses: ["ceci n'est pas du JSON"], finalAnswerResponse: "réponse malgré planner imparsable")
        let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "question")

        #expect(result.answer == "réponse malgré planner imparsable")
        // 1 classification + 1 seul tour planner (fallback "done" immédiat,
        // sortie imparsable) + 1 génération finale.
        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 3)
    }

    @Test("decideNextAction : JSON valide avec action scrapeURL est parsé correctement")
    func decideNextActionParsesValidScrapeURLJSON() {
        let raw = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example"],"reasoning":"pour approfondir"}
        """
        let decision = SearchOrchestrator.decideNextAction(rawOutput: raw)

        #expect(decision.actionName == "scrapeURL")
        #expect(decision.urls == ["https://a.example", "https://b.example"])
        #expect(decision.reasoning == "pour approfondir")
    }

    @Test("decideNextAction : sortie totalement invalide retombe sur 'done'")
    func decideNextActionFallsBackToDoneOnInvalidOutput() {
        let decision = SearchOrchestrator.decideNextAction(rawOutput: "n'importe quoi, pas du JSON")

        #expect(decision.actionName == "done")
        #expect(decision.urls.isEmpty)
    }
}
