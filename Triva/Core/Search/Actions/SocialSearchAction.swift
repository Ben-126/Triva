//
//  SocialSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port de `socialSearch.ts` (web) : moteur `reddit` forcé, sans restriction
/// de catégorie — même principe que `AcademicSearchAction`, une seule
/// surcharge `engines` passée à la recherche. Action du tour seedé de la
/// route `.web(.discussion)` (`SearchRoute.resolve`, `WebSearchFlavor.action`) ;
/// restée vide, elle est relancée une fois en `WebSearchAction` (bug 5,
/// `SearchOrchestrator.seededSearch`).
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
