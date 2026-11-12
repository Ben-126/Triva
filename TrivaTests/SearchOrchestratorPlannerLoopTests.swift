//
//  SearchOrchestratorPlannerLoopTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Boucle planner de `SearchOrchestratorTests`.

extension SearchOrchestratorTests {
    // MARK: - Boucle planner (scrapeURL / done / bornage)

    @Test("Requête complexe : le planner déclenche scrapeURL avec 3 sources affichées puis done -> pages fusionnées dans leurs sources, sans document en plus")
    func plannerScrapesThenStops() async throws {
        let results = ["a", "b", "c", "d"].map { Self.makeResult(title: "Titre \($0.uppercased())", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let scrapeJSON = """
        {"action":"scrapeURL","urls":["https://a.example","https://b.example","https://c.example"]}
        """
        let doneJSON = """
        {"action":"done","urls":[]}
        """
        let aiProvider = PipelineMockAIGenerating(plannerResponses: [scrapeJSON, doneJSON], finalAnswerResponse: "réponse enrichie")
        let orchestrator = makePipelineOrchestrator(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            scrapeService: PipelineMockScrapeService(succeeded: true)
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
        let failoverManager = FailoverManager(client: PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: [])), instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(plannerResponses: [
            #"{"action":"scrapeURL","urls":["https://1.example"]}"#,
            #"{"action":"scrapeURL","urls":["https://2.example"]}"#,
        ])
        let orchestrator = makePipelineOrchestrator(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            scrapeService: PipelineMockScrapeService(succeeded: true),
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
        let failoverManager = FailoverManager(client: PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: [])), instances: [Self.instance])
        let aiProvider = PipelineMockAIGenerating(plannerResponses: ["ceci n'est pas du JSON"], finalAnswerResponse: "réponse malgré planner imparsable")
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

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
}
