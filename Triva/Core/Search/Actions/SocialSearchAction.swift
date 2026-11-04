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
/// route `.web(.discussion)` (`SearchRoute.resolve`,
/// `WebSearchFlavor.action(webSearchChain:)`).
///
/// Sans chaîne : SearXNG seul ; restée vide, elle est relancée une fois en
/// `WebSearchAction` (bug 5, `SearchOrchestrator.seededWebSearch`). Avec la
/// chaîne de repli (RI1b) : catégorie `.discussion` ; ce repli web a alors
/// lieu dans l'étape SearXNG de la chaîne, et les sources ouvertes sont
/// celles des discussions (Marginalia, Wikipédia).
/// Moteur : `SearXNGWebSearchProvider.discussionEngines`, le même que l'étape
/// SearXNG de la chaîne.
struct SocialSearchAction: WebSearchingAction {
    let name = "socialSearch"
    let descriptionForPlanner = "Recherche communautaire : à utiliser pour des avis, discussions ou expériences partagées par des utilisateurs (Reddit)."
    let webSearchCategory: WebSearchCategory = .discussion
    let webSearchChain: WebSearchChain?

    init(webSearchChain: WebSearchChain? = nil) {
        self.webSearchChain = webSearchChain
    }

    func searchSearXNGOnly(query: String, failoverManager: FailoverManager) async throws -> SearXNGSearchResponse {
        let options = SearXNGSearchOptions(engines: SearXNGWebSearchProvider.discussionEngines)
        return try await failoverManager.search(query: query, options: options)
    }
}
