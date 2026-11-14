//
//  SearchOrchestratorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("SearchOrchestrator")
struct SearchOrchestratorTests {
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

    /// JSON de classification valide pour `QueryClassifier.parse` : tous les
    /// booléens à `false` sauf ceux passés à `true`.
    static func classificationJSON(
        skipSearch: Bool = false,
        personalSearch: Bool = false,
        academicSearch: Bool = false,
        discussionSearch: Bool = false,
        showWeatherWidget: Bool = false,
        showStockWidget: Bool = false,
        showCalculationWidget: Bool = false,
        textTask: Bool? = nil,
        standaloneFollowUp: String
    ) -> String {
        // `textTask` absent du JSON quand il vaut `nil` : un modèle qui ignore ce champ (cas par défaut).
        let textTaskField = textTask.map { ",\"textTask\":\($0)" } ?? ""
        return """
        {"classification":{"skipSearch":\(skipSearch),"personalSearch":\(personalSearch),"academicSearch":\(academicSearch),\
        "discussionSearch":\(discussionSearch),"showWeatherWidget":\(showWeatherWidget),"showStockWidget":\(showStockWidget),\
        "showCalculationWidget":\(showCalculationWidget)\(textTaskField)},"standaloneFollowUp":"\(standaloneFollowUp)"}
        """
    }

    // MARK: - Cas nominal (pipeline complet : classification -> webSearch -> planner "done")

    @Test("Cas nominal : réponse et sources correspondent au mock, le prompt final contient la requête et le contexte")
    func happyPath() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "voici la réponse")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 2)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.count == 2)
        #expect(result.sources.map(\.title) == ["Titre 1", "Titre 2"])
    }

    @Test("Zéro résultat de recherche : le provider IA est quand même appelé, sans crash")
    func zeroSearchResultsStillCallsAIProvider() async throws {
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "réponse sans contexte")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête sans résultat")

        #expect(result.answer == "réponse sans contexte")
        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("requête sans résultat"))
    }

    @Test("Un résultat sans contenu (nil) est géré sans crash")
    func resultWithoutContentDoesNotCrash() async throws {
        let results = [Self.makeResult(title: "Titre sans contenu", url: "https://sans-contenu.example", content: nil)]
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources == results)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Titre sans contenu"))
    }

    @Test("Une erreur de FailoverManager remonte inchangée ; la classification a déjà eu lieu (1 appel), mais ni planner ni génération finale ne sont atteints")
    func failoverErrorPropagatesWithoutCallingAIProvider() async {
        let client = PipelineMockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(shouldFailFinalGeneration: true)
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: PipelineMockError.generationFailed) {
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
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "réponse malgré planner en échec", plannerError: PipelineMockError.generationFailed)
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

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
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "réponse malgré classification en échec", shouldFailClassification: true)
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "réponse malgré requête vide")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "")

        #expect(result.answer == "réponse malgré requête vide")
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        // Dernière ligne du prompt de rédaction (`PromptTemplates`, .full).
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : "))
    }

    @Test("Une requête composée uniquement d'espaces est transmise telle quelle, sans normalisation")
    func whitespaceOnlyQueryIsPassedThroughUnchanged() async throws {
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "réponse malgré requête blanche")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "   ")

        #expect(result.answer == "réponse malgré requête blanche")
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : " + "   "))
    }

    @Test("maxResultsUsedForContext = 0 produit un contexte et des sources vides, sans crash")
    func zeroMaxResultsUsedForContextProducesEmptyContext() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(finalAnswerResponse: "réponse sans contexte")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider, maxResultsUsedForContext: 0)

        let result = try await orchestrator.answer(query: "requête")

        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(!finalPrompt.contains("Titre A"))
    }

    // MARK: - Routage de la classification (1.2)

    @Test("Classification .skip : aucune recherche lancée, sources/contexte vides, le provider IA génère quand même une réponse")
    func skipClassificationLaunchesNoSearch() async throws {
        let client = PipelineMockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let skipJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "bonjour")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: skipJSON, finalAnswerResponse: "salut !")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let greetingClient = PipelineMockSearXNGClient()
        let greetingProvider = PipelineMockAIGenerating(finalAnswerResponse: "Bonjour !", shouldFailClassification: true)
        let greetingOrchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: greetingClient, instances: [Self.instance]),
            aiProvider: greetingProvider,
            responseMode: .reliable
        )
        let greeting = try await greetingOrchestrator.answer(query: "Bonjour !")
        #expect(greeting.answer == "Bonjour !")
        #expect(await greetingClient.callCount == 0)

        let questionClient = PipelineMockSearXNGClient()
        let questionProvider = PipelineMockAIGenerating(shouldFailClassification: true)
        let questionOrchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: questionClient, instances: [Self.instance]),
            aiProvider: questionProvider
        )
        _ = try await questionOrchestrator.answer(query: "Quelle est la hauteur de la tour Eiffel ?")
        #expect(await questionClient.callCount > 0)
    }

    @Test("Classification academicSearch : AcademicSearchAction utilisée, moteurs arxiv/google scholar/pubmed forcés")
    func academicSearchRoutesToAcademicAction() async throws {
        let client = PipelineMockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let academicJSON = Self.classificationJSON(academicSearch: true, standaloneFollowUp: "études sur X")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: academicJSON)
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "études récentes sur X")

        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first?.engines == ["arxiv", "google scholar", "pubmed"])
    }

    @Test("Classification discussionSearch : SocialSearchAction utilisée, moteur reddit forcé")
    func discussionSearchRoutesToSocialAction() async throws {
        let client = PipelineMockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let discussionJSON = Self.classificationJSON(discussionSearch: true, standaloneFollowUp: "avis sur Y")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: discussionJSON)
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
        let client = PipelineMockSearXNGClient(
            response: SearXNGSearchResponse(results: results, suggestions: []),
            forcedEnginesResponse: SearXNGSearchResponse(results: [], suggestions: [])
        )
        let classification = academic
            ? Self.classificationJSON(academicSearch: true, standaloneFollowUp: "études sur X")
            : Self.classificationJSON(discussionSearch: true, standaloneFollowUp: "études sur X")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: classification)
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "et pour X ?")

        #expect(result.sources == results)
        let forcedEngines = academic ? ["arxiv", "google scholar", "pubmed"] : ["reddit"]
        #expect(await client.receivedOptions == [SearXNGSearchOptions(engines: forcedEngines), SearXNGSearchOptions()])
        #expect(await client.receivedQueries == ["études sur X", "études sur X"])
    }

    @Test("Bug 5 : une recherche web par défaut sans résultat n'est PAS relancée — une vraie recherche vide reste valide")
    func emptyDefaultWebSearchIsNotRetried() async throws {
        let client = PipelineMockSearXNGClient()
        let aiProvider = PipelineMockAIGenerating()
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "requête sans résultat")

        #expect(result.sources.isEmpty)
        #expect(await client.callCount == 1)
    }

    @Test("Bug 5 : moteurs forcés AVEC résultats -> aucun repli, un seul appel")
    func forcedEngineSearchWithResultsKeepsThem() async throws {
        let redditResults = [Self.makeResult(title: "Fil Reddit", url: "https://reddit.example/r/x", content: "Avis")]
        let client = PipelineMockSearXNGClient(forcedEnginesResponse: SearXNGSearchResponse(results: redditResults, suggestions: []))
        let aiProvider = PipelineMockAIGenerating(classifyResponse: Self.classificationJSON(discussionSearch: true, standaloneFollowUp: "avis sur Y"))
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let result = try await orchestrator.answer(query: "avis des gens sur Y")

        #expect(result.sources == redditResults)
        #expect(await client.callCount == 1)
    }
}
