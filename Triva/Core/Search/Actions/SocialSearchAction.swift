//
//  SocialSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port de `socialSearch.ts` (web) : moteur `reddit` forcé, sans restriction
/// de catégorie — même principe que `AcademicSearchAction`, une seule
/// surcharge `engines` passée à la recherche. Sélectionnée quand
/// `QueryClassification.primaryAction == .discussionSearch` (voir
/// `SearchOrchestrator`).
struct SocialSearchAction: SearchAction {
    let name = "socialSearch"
    let descriptionForPlanner = "Recherche communautaire : à utiliser pour des avis, discussions ou expériences partagées par des utilisateurs (Reddit)."

    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        let options = SearXNGSearchOptions(engines: ["reddit"])
        let response = try await failoverManager.search(query: query, options: options)
        return .searchResults(response.results)
    }
}
