//
//  SearchOrchestratorAgenticTests+Doubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import Synchronization
@testable import Triva

/// Enquêteur factice (tâche 2.4) : joue un scénario avec les VRAIS outils (`WebSearchTool`, `ReadPageTool`) sur
/// les closures `search`/`scrape` que l'orchestrateur lui donne. Prouve donc aussi le câblage de ces closures
/// (même chaîne de recherche, même service de lecture), sans modèle.
nonisolated final class StubAgenticResearcher: AgenticResearching {
    nonisolated enum Script: Sendable {
        /// Une recherche de l'enquêteur, puis la lecture des numéros donnés, puis `finish`.
        case searchAndRead(query: String, reads: [Int])
        /// Fin immédiate, sans rien chercher ni lire.
        case finishImmediately
        /// Délai écoulé sans rien trouver.
        case timeOutEmpty
        case fail(AgenticFallbackReason)
        case cancel
    }

    private let script: Script
    private let requestLog = Mutex<[AgenticResearchRequest]>([])
    private let threadLog = Mutex<[Bool]>([])

    init(_ script: Script) { self.script = script }

    var requests: [AgenticResearchRequest] { requestLog.withLock { $0 } }
    /// `true` pour chaque appel fait sur le fil principal.
    var calledOnMainThread: [Bool] { threadLog.withLock { $0 } }

    func investigate(_ request: AgenticResearchRequest) async throws -> AgenticResearchOutcome {
        requestLog.withLock { $0.append(request) }
        threadLog.withLock { $0.append(pthread_main_np() != 0) }
        let ledger = ResearchLedger(budget: request.budget, trustedDomainsOnly: request.trustedDomainsOnly, seeded: request.seeded)
        switch script {
        case .searchAndRead(let query, let reads):
            _ = try await WebSearchTool(ledger: ledger, search: request.search).run(query: query)
            for number in reads {
                _ = try await ReadPageTool(ledger: ledger, scrape: request.scrape, focusQuery: request.searchQuery).run(number: number)
            }
            _ = FinishResearchTool(ledger: ledger).run()
            return AgenticResearchOutcome(snapshot: ledger.snapshot, stop: .finished)
        case .finishImmediately:
            return AgenticResearchOutcome(snapshot: ledger.snapshot, stop: .finished)
        case .timeOutEmpty:
            return AgenticResearchOutcome(snapshot: ledger.snapshot, stop: .timedOut)
        case .fail(let reason):
            throw AgenticResearchFailure(reason: reason)
        case .cancel:
            throw CancellationError()
        }
    }
}

/// Client SearXNG qui rend des résultats DIFFÉRENTS selon la requête : la recherche de l'enquêteur
/// (`agentQuery`) rend `agentResults`, toute autre requête (le départ) rend `seededResults`.
actor QueryRoutedSearXNGClient {
    private let seededResults: [SearXNGSearchResult]
    private let agentQuery: String
    private let agentResults: [SearXNGSearchResult]
    private(set) var receivedQueries: [String] = []

    init(seededResults: [SearXNGSearchResult], agentQuery: String = "", agentResults: [SearXNGSearchResult] = []) {
        self.seededResults = seededResults
        self.agentQuery = agentQuery
        self.agentResults = agentResults
    }
}

// Conformité dans une extension, comme `PipelineMockSearXNGClient` : déclarée sur l'acteur lui-même, la cible
// de test iOS ne compilait pas (erreurs « 'nonisolated' … » sur l'acteur et son init, la cible Mac si).
extension QueryRoutedSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedQueries.append(query)
        let results = query == agentQuery ? agentResults : seededResults
        return SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Orchestrateur de test de la tâche 2.4 : init PRINCIPAL (avec `isOffline` et `agenticResearcher`),
/// classement qui garde l'ordre du moteur, lecture factice, aucun widget par défaut (`widgets` : F3).
@MainActor
func makeAgenticOrchestrator(
    client: any SearXNGSearching,
    aiProvider: any AIGenerating,
    responseMode: ResponseMode = .deep,
    researcher: (any AgenticResearching)?,
    isOffline: Bool = false,
    widgets: [any SearchWidget] = []
) -> SearchOrchestrator {
    let configuration = SearchPipelineConfiguration(
        promptComplexity: .full,
        maxHistoryMessages: PromptTemplates.defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: PromptTemplates.defaultMaxHistoryMessageCharacters,
        maxScrapedContextCharacters: PromptTemplates.defaultMaxScrapedContextCharacters,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )
    return SearchOrchestrator(
        failoverManager: FailoverManager(client: client, instances: [SearchOrchestratorTests.instance]),
        aiProvider: aiProvider,
        responseMode: responseMode,
        configuration: configuration,
        scrapeService: PipelineMockScrapeService(succeeded: true),
        sourceRanker: pipelineOrderPreservingRanker(),
        widgets: widgets,
        isOffline: isOffline,
        agenticResearcher: researcher
    )
}

/// Résultat de test, sans isolation (les fabriques de `SearchOrchestratorTests` sont isolées au main actor).
nonisolated func investigatorTestResult(title: String, url: String, content: String?) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: title, url: url, content: content, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    )
}

/// Trois résultats de départ, avec extrait (aucune lecture préalable par `preRead`).
nonisolated func agenticSeededResults() -> [SearXNGSearchResult] {
    ["a", "b", "c"].map {
        investigatorTestResult(title: "Départ \($0.uppercased())", url: "https://\($0).example", content: "Extrait \($0)")
    }
}

/// Deux résultats que seule la recherche de l'enquêteur trouve.
nonisolated func agenticFoundResults() -> [SearXNGSearchResult] {
    ["d", "e"].map {
        investigatorTestResult(title: "Trouvé \($0.uppercased())", url: "https://\($0).example", content: "Extrait \($0)")
    }
}
