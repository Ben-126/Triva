//
//  SearchOrchestratorTestSupport.swift
//  TrivaTests
//
//  Created by ben podrojsky on 01/11/2026.
//

import Foundation
@testable import Triva

extension SearchOrchestrator {
    /// Init historique, réglage par réglage : ses défauts SONT le préréglage
    /// `.cloud`. Réservé aux tests (déplacé hors de l'app le 2026-11-01) : l'app
    /// passe toujours par `init(…configuration:…)`, avec le budget du moteur actif.
    /// `writerComplexity` y règle aussi le classifieur.
    @MainActor
    init(
        failoverManager: FailoverManager,
        aiProvider: any AIGenerating,
        responseMode: ResponseMode = .quick,
        queryClassifier: QueryClassifier? = nil,
        scrapeService: any ScrapeServing = ScrapeService(),
        sourceRanker: SourceRanker = SourceRanker(),
        writerComplexity: WriterPromptComplexity = .full,
        maxResultsUsedForContext: Int = 5,
        maxIterations: Int = 3,
        maxScrapedURLsPerIteration: Int = 3,
        maxScrapedContextCharacters: Int = PromptTemplates.defaultMaxScrapedContextCharacters,
        maxHistoryMessages: Int = PromptTemplates.defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: Int = PromptTemplates.defaultMaxHistoryMessageCharacters,
        scrapeRoundTimeout: Duration = SearchOrchestrator.defaultScrapeRoundTimeout,
        clock: any Clock<Duration> = ContinuousClock(),
        widgets: [any SearchWidget]? = nil,
        mediaSearcher: (any MediaSearching)? = nil,
        mediaGracePeriod: Duration = SearchOrchestrator.defaultMediaGracePeriod
    ) {
        let configuration = SearchPipelineConfiguration(
            promptComplexity: writerComplexity,
            maxHistoryMessages: maxHistoryMessages,
            maxHistoryMessageCharacters: maxHistoryMessageCharacters,
            maxScrapedContextCharacters: maxScrapedContextCharacters,
            maxResultsUsedForContext: maxResultsUsedForContext,
            maxScrapedURLsPerIteration: maxScrapedURLsPerIteration
        )
        self.init(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            responseMode: responseMode,
            configuration: configuration,
            queryClassifier: queryClassifier,
            scrapeService: scrapeService,
            sourceRanker: sourceRanker,
            maxIterations: maxIterations,
            scrapeRoundTimeout: scrapeRoundTimeout,
            clock: clock,
            widgets: widgets,
            mediaSearcher: mediaSearcher,
            mediaGracePeriod: mediaGracePeriod
        )
    }
}
