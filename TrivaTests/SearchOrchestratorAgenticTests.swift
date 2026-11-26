//
//  SearchOrchestratorAgenticTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Aiguillage de la recherche menée par l'IA dans l'orchestrateur (tâche 2.4, mission M3, spec §2 et §2.6),
/// avec un enquêteur factice qui se sert des vrais outils.
@MainActor
@Suite("SearchOrchestrator : enquêteur (2.4)")
struct SearchOrchestratorAgenticTests {
    static let agentQuery = "requête de l'enquêteur"

    private func routedClient() -> QueryRoutedSearXNGClient {
        QueryRoutedSearXNGClient(seededResults: agenticSeededResults(), agentQuery: Self.agentQuery, agentResults: agenticFoundResults())
    }

    private func plannerWasCalled(_ provider: PipelineMockAIGenerating) -> Bool {
        provider.receivedPrompts.contains { $0.contains("<planner_context>") }
    }

    // MARK: - Succès

    @Test("Succès : page lue en tête des sources, contenu dans le prompt, ni planner ni lecture préalable, chemin .agentic")
    func successUsesInvestigatorSources() async throws {
        let client = routedClient()
        let provider = PipelineMockAIGenerating(finalAnswerResponse: "réponse [1]")
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [4]))
        let orchestrator = makeAgenticOrchestrator(client: client, aiProvider: provider, researcher: researcher)

        let result = try await orchestrator.answer(query: "question test")

        #expect(result.artifacts.researchPath == .agentic)
        #expect(result.sources.map(\.url) == ["https://d.example", "https://a.example", "https://b.example", "https://c.example", "https://e.example"])
        let finalPrompt = try #require(provider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu scrapé pour https://d.example"))
        #expect(!plannerWasCalled(provider))
        #expect(await client.receivedQueries.count == 2)
        #expect(await client.receivedQueries.last == Self.agentQuery)
        #expect(result.artifacts.citableSourceCount == 5)
        #expect(result.answer == "réponse [1]")
    }

    @Test("Requête transmise : question, sujet, résultats de départ bruts, budget Approfondie, pas de filtre fiable")
    func requestCarriesSendContext() async throws {
        let researcher = StubAgenticResearcher(.finishImmediately)
        let orchestrator = makeAgenticOrchestrator(client: routedClient(), aiProvider: PipelineMockAIGenerating(), researcher: researcher)

        _ = try await orchestrator.answer(query: "question test")

        let request = try #require(researcher.requests.first)
        #expect(researcher.requests.count == 1)
        #expect(request.question == "question test")
        #expect(request.searchQuery == "question test")
        #expect(request.seeded.map(\.url) == agenticSeededResults().map(\.url))
        #expect(request.budget == ResearchBudget(maxSearches: 2, maxReads: 4, maxToolCalls: 8, timeout: .seconds(30)))
        #expect(!request.trustedDomainsOnly)
    }

    @Test("L'enquêteur tourne hors du fil principal, même appelé depuis le main actor")
    func investigatorRunsOffMainThread() async throws {
        let researcher = StubAgenticResearcher(.finishImmediately)
        let orchestrator = makeAgenticOrchestrator(client: routedClient(), aiProvider: PipelineMockAIGenerating(), researcher: researcher)

        _ = try await orchestrator.answer(query: "question test")

        #expect(researcher.calledOnMainThread == [false])
    }

    @Test("Flux : les artefacts portent aussi le chemin .agentic")
    func streamingCarriesResearchPath() async throws {
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [1]))
        let orchestrator = makeAgenticOrchestrator(client: routedClient(), aiProvider: PipelineMockStreamingProvider(), researcher: researcher)

        let streaming = try await orchestrator.streamAnswer(query: "question test")

        #expect(streaming.artifacts.researchPath == .agentic)
        #expect(streaming.sources.first?.url == "https://a.example")
    }

    // MARK: - Replis

    @Test("Erreur de l'enquêteur : boucle actuelle sur le MÊME départ (une seule recherche), raison notée")
    func failureFallsBackWithoutSecondSeededSearch() async throws {
        let client = routedClient()
        let provider = PipelineMockAIGenerating()
        let orchestrator = makeAgenticOrchestrator(client: client, aiProvider: provider, researcher: StubAgenticResearcher(.fail(.contextExceeded)))

        let result = try await orchestrator.answer(query: "question test")

        #expect(result.artifacts.researchPath == .agenticFellBack(.contextExceeded))
        #expect(await client.receivedQueries.count == 1)
        #expect(plannerWasCalled(provider))
        #expect(result.sources.map(\.url) == agenticSeededResults().map(\.url))
    }

    @Test("Registre sans trouvaille : boucle actuelle, raison .noFindings")
    func emptyLedgerFallsBack() async throws {
        let client = routedClient()
        let provider = PipelineMockAIGenerating()
        let orchestrator = makeAgenticOrchestrator(client: client, aiProvider: provider, researcher: StubAgenticResearcher(.finishImmediately))

        let result = try await orchestrator.answer(query: "question test")

        #expect(result.artifacts.researchPath == .agenticFellBack(.noFindings))
        #expect(await client.receivedQueries.count == 1)
        #expect(plannerWasCalled(provider))
    }

    @Test("Délai écoulé sans rien trouver : boucle actuelle, raison .timedOut")
    func timeoutWithoutFindingsFallsBack() async throws {
        let orchestrator = makeAgenticOrchestrator(
            client: routedClient(), aiProvider: PipelineMockAIGenerating(), researcher: StubAgenticResearcher(.timeOutEmpty)
        )

        let result = try await orchestrator.answer(query: "question test")

        #expect(result.artifacts.researchPath == .agenticFellBack(.timedOut))
    }

    @Test("Annulation dans l'enquêteur : remonte telle quelle, aucun repli ni génération finale")
    func cancellationPropagates() async throws {
        let provider = PipelineMockAIGenerating()
        let orchestrator = makeAgenticOrchestrator(client: routedClient(), aiProvider: provider, researcher: StubAgenticResearcher(.cancel))

        await #expect(throws: CancellationError.self) {
            _ = try await orchestrator.answer(query: "question test")
        }
        #expect(!plannerWasCalled(provider))
        #expect(provider.receivedPrompts.count == 1)
    }

    // MARK: - Enquêteur jamais appelé

    @Test("Mode Rapide : enquêteur jamais appelé, chemin .classic")
    func quickModeNeverInvestigates() async throws {
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [1]))
        let orchestrator = makeAgenticOrchestrator(
            client: routedClient(), aiProvider: PipelineMockAIGenerating(), responseMode: .quick, researcher: researcher
        )

        let result = try await orchestrator.answer(query: "question test")

        #expect(researcher.requests.isEmpty)
        #expect(result.artifacts.researchPath == .classic)
    }

    @Test("Hors connexion : enquêteur jamais appelé")
    func offlineNeverInvestigates() async throws {
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [1]))
        let orchestrator = makeAgenticOrchestrator(
            client: routedClient(), aiProvider: PipelineMockAIGenerating(), researcher: researcher, isOffline: true
        )

        let result = try await orchestrator.answer(query: "question test")

        #expect(researcher.requests.isEmpty)
        #expect(result.artifacts.researchPath == .classic)
    }

    @Test("Sans enquêteur (MLX, clés cloud, drapeau éteint) : chemin .classic, comportement d'avant")
    func nilResearcherKeepsClassicPath() async throws {
        let client = routedClient()
        let provider = PipelineMockAIGenerating()
        let orchestrator = makeAgenticOrchestrator(client: client, aiProvider: provider, researcher: nil)

        let result = try await orchestrator.answer(query: "question test")

        #expect(result.artifacts.researchPath == .classic)
        #expect(await client.receivedQueries.count == 1)
        #expect(plannerWasCalled(provider))
    }

    // MARK: - Mode Fiable

    @Test("Fiable sans aucun domaine fiable : filtre transmis, repli, lacksReliableSources comme aujourd'hui")
    func reliableWithoutTrustedDomainsLacksSources() async throws {
        let client = routedClient()
        let provider = PipelineMockAIGenerating()
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [1]))
        let orchestrator = makeAgenticOrchestrator(client: client, aiProvider: provider, responseMode: .reliable, researcher: researcher)

        let result = try await orchestrator.answer(query: "question test")

        #expect(researcher.requests.first?.trustedDomainsOnly == true)
        #expect(result.artifacts.researchPath == .agenticFellBack(.noFindings))
        #expect(result.artifacts.lacksReliableSources)
        #expect(result.answer.isEmpty)
        #expect(!provider.receivedPrompts.contains { $0.contains("Contenu scrapé") })
    }

    @Test("Budget : lectures bornées au nombre effectif de sources affichées ; Rapide sans enquêteur")
    func budgetCappedByEffectiveSourceLimit() {
        let configuration = SearchPipelineConfiguration.appleIntelligence
        #expect(!SearchOrchestrator.agenticBudget(mode: .quick, configuration: configuration, effectiveSourceLimit: 3).isEnabled)
        #expect(SearchOrchestrator.agenticBudget(mode: .deep, configuration: configuration, effectiveSourceLimit: 2).maxReads == 2)
        let reliable = SearchOrchestrator.agenticBudget(mode: .reliable, configuration: configuration, effectiveSourceLimit: 5)
        #expect(reliable.maxReads == min(3, configuration.maxResultsUsedForContext))
        #expect(reliable.maxSearches == 2)
        #expect(reliable.timeout == .seconds(25))
    }
}

/// Fournisseur minimal pour `streamAnswer` : classification par défaut, flux d'un morceau.
final class PipelineMockStreamingProvider: AIGenerating {
    func generate(prompt: String) async throws -> String { "" }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("réponse")
            continuation.finish()
        }
    }
}
