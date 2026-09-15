//
//  AcademicSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port de `academicSearch.ts` (web) : mêmes 3 moteurs forcés
/// (`arxiv`, `google scholar`, `pubmed`), sans restriction de catégorie — côté
/// web, `searchConfig: { engines: [...] }` est la SEULE surcharge passée à
/// `executeSearch`, `categories` reste vide comme pour `WebSearchAction`.
/// Sélectionnée quand `QueryClassification.primaryAction == .academicSearch`
/// (voir `SearchOrchestrator`).
struct AcademicSearchAction: SearchAction {
    let name = "academicSearch"
    let descriptionForPlanner = "Recherche académique : à utiliser pour des articles scientifiques, études ou publications de recherche (arXiv, Google Scholar, PubMed)."

    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        let options = SearXNGSearchOptions(engines: ["arxiv", "google scholar", "pubmed"])
        let response = try await failoverManager.search(query: query, options: options)
        return .searchResults(response.results)
    }
}
