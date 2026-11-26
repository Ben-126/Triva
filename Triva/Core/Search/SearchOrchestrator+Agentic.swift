//
//  SearchOrchestrator+Agentic.swift
//  Triva
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import os

/// Aiguillage de la recherche menée par l'IA (tâche 2.4, spec §2 et §2.6), appelé par `webResearch`
/// juste après le tour seedé :
/// - pas d'enquêteur (`agenticResearcher == nil`, cas de MLX, des clés cloud et du drapeau éteint) ou budget
///   nul (mode Rapide) : `.notAttempted`, la boucle actuelle tourne exactement comme avant ;
/// - enquête aboutie avec des trouvailles : sources et pages assemblées par `AgenticSourceSelection`, SANS
///   `preRead` ni planner (l'enquêteur a choisi), rédacteur inchangé ;
/// - échec, ou registre sans rien de plus que le départ : `.fellBack`, la boucle actuelle reprend sur les
///   résultats de départ DÉJÀ obtenus (aucune deuxième recherche de départ) ;
/// - annulation (Stop) : remonte telle quelle.
extension SearchOrchestrator {
    nonisolated enum AgenticAttempt: Sendable {
        case notAttempted
        case succeeded(WebResearch)
        case fellBack(AgenticFallbackReason)
    }

    /// Journal de diagnostic : chemin suivi et compteurs, jamais de contenu de page, de requête ni d'hôte.
    nonisolated static let agenticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Triva", category: "AgenticResearch")

    /// Budget de l'enquêteur pour ce mode, les lectures bornées au nombre EFFECTIF de sources affichées
    /// (`min(plafond, valeur du mode)`) : une page lue au-delà serait jetée par `finalSources(limit:)`.
    nonisolated static func agenticBudget(mode: ResponseMode, configuration: SearchPipelineConfiguration, effectiveSourceLimit: Int) -> ResearchBudget {
        let budget = ResearchBudget.for(mode: mode, configuration: configuration)
        guard budget.isEnabled else { return budget }
        return ResearchBudget(
            maxSearches: budget.maxSearches,
            maxReads: max(0, min(budget.maxReads, effectiveSourceLimit)),
            maxToolCalls: budget.maxToolCalls,
            timeout: budget.timeout
        )
    }

    nonisolated func attemptAgenticResearch(
        question: String,
        searchQuery: String,
        flavor: WebSearchFlavor,
        seeded: SeededWebSearch,
        seededResults: [SearXNGSearchResult]
    ) async throws -> AgenticAttempt {
        guard let agenticResearcher, agenticBudget.isEnabled else { return .notAttempted }
        let request = agenticRequest(question: question, searchQuery: searchQuery, flavor: flavor, seededResults: seededResults)
        let outcome: AgenticResearchOutcome
        do {
            outcome = try await agenticResearcher.investigate(request)
        } catch {
            if Self.isCancellation(error) { throw error }
            let reason = (error as? AgenticResearchFailure)?.reason ?? .other
            Self.agenticLogger.notice("Enquête abandonnée : \(String(describing: reason), privacy: .public)")
            return .fellBack(reason)
        }
        try Task.checkCancellation()
        return await assemble(outcome, searchQuery: searchQuery, seeded: seeded, seededResults: seededResults)
    }

    /// Requête de l'enquêteur : la recherche passe par la MÊME chaîne que le départ (`seededWebSearch`), la
    /// lecture par le même `scrapeService`.
    private nonisolated func agenticRequest(
        question: String,
        searchQuery: String,
        flavor: WebSearchFlavor,
        seededResults: [SearXNGSearchResult]
    ) -> AgenticResearchRequest {
        let chain = webSearchChain
        let failover = failoverManager
        let trusted = restrictsToTrustedDomains
        let scraper = scrapeService
        return AgenticResearchRequest(
            question: question,
            searchQuery: searchQuery,
            seeded: seededResults,
            budget: agenticBudget,
            trustedDomainsOnly: trusted,
            search: { query in
                let found = try await Self.seededWebSearch(
                    flavor: flavor, query: query, webSearchChain: chain, trustedDomainsOnly: trusted, failoverManager: failover
                )
                guard case .searchResults(let results) = found.output else { return [] }
                return results
            },
            scrape: { url in await scraper.scrape(url: url) },
            today: Date()
        )
    }

    /// Assemblage des sources finales (spec §2.4). Rien de plus que le départ, ou aucune source retenue :
    /// repli (la boucle actuelle sait au moins lire les sources sans extrait).
    private nonisolated func assemble(
        _ outcome: AgenticResearchOutcome,
        searchQuery: String,
        seeded: SeededWebSearch,
        seededResults: [SearXNGSearchResult]
    ) async -> AgenticAttempt {
        let snapshot = outcome.snapshot
        let emptyReason: AgenticFallbackReason = outcome.stop == .timedOut ? .timedOut : .noFindings
        guard snapshot.hasFindings else { return .fellBack(emptyReason) }
        let candidates = AgenticSourceSelection.union(seeded: seededResults, found: snapshot.foundResults)
        let ranked = await sourceRanker.rank(
            query: searchQuery,
            results: candidates,
            limit: maxResultsUsedForContext,
            trustedDomainsOnly: restrictsToTrustedDomains
        ).map(\.result)
        let selection = AgenticSourceSelection.finalSources(
            seeded: seededResults,
            found: snapshot.foundResults,
            readPages: snapshot.readPages.map(\.page),
            ranked: ranked,
            limit: maxResultsUsedForContext,
            trustedDomainsOnly: restrictsToTrustedDomains
        )
        guard !selection.sources.isEmpty else { return .fellBack(emptyReason) }
        Self.agenticLogger.notice(
            "Enquête : \(snapshot.searchCount) recherches, \(snapshot.successfulPages.count)/\(snapshot.readCount) pages lues, \(selection.sources.count) sources"
        )
        return .succeeded(WebResearch(
            documents: [],
            sources: selection.sources,
            scrapedPages: selection.pages,
            webSourceKind: seeded.sourceKind,
            webSearchReport: Self.report(seeded.report, rejudgedOn: selection.sources, query: searchQuery, hasChain: webSearchChain != nil),
            researchPath: .agentic
        ))
    }
}
