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
/// Action du tour seedé de la route `.web(.academic)` (`SearchRoute.resolve`,
/// `WebSearchFlavor.action(webSearchChain:)`).
///
/// Sans chaîne : SearXNG seul ; restée vide, elle est relancée une fois en
/// `WebSearchAction` (bug 5, `SearchOrchestrator.seededWebSearch`). Avec la
/// chaîne de repli (RI1b) : catégorie `.academic` ; ce repli web a alors lieu
/// dans l'étape SearXNG de la chaîne, et les sources ouvertes sont celles de
/// la recherche académique (OpenAlex, arXiv, Wikipédia).
/// Moteurs : `SearXNGWebSearchProvider.academicEngines`, les mêmes que l'étape
/// SearXNG de la chaîne — une seule liste, les deux chemins ne divergent pas.
struct AcademicSearchAction: WebSearchingAction {
    let name = "academicSearch"
    let descriptionForPlanner = "Recherche académique : à utiliser pour des articles scientifiques, études ou publications de recherche (arXiv, Google Scholar, PubMed)."
    let webSearchCategory: WebSearchCategory = .academic
    let webSearchChain: WebSearchChain?

    init(webSearchChain: WebSearchChain? = nil) {
        self.webSearchChain = webSearchChain
    }

    func searchSearXNGOnly(query: String, failoverManager: FailoverManager) async throws -> SearXNGSearchResponse {
        let options = SearXNGSearchOptions(engines: SearXNGWebSearchProvider.academicEngines)
        return try await failoverManager.search(query: query, options: options)
    }
}
