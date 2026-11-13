//
//  WebSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port de la version web d'origine : recherche web générale, sans restriction de
/// catégories ni de moteurs — SearXNG interroge son jeu de moteurs par
/// défaut, exactement comme dans la version web d'origine (`executeSearch` n'y reçoit aucun
/// `searchConfig`, contrairement aux recherches académique et sociale).
/// La recherche de base de la version web d'origine n'a servi ici qu'à comprendre CETTE forme de
/// requête : le scoring qu'il applique ensuite (`BOOSTED_DOMAINS`,
/// similarité cosinus, dédoublonnage par embedding) est hors scope de 1.2,
/// réservé à `SourceRanker` (1.3) — cette action renvoie les résultats bruts
/// de la source qui a répondu, non triés.
///
/// Chaîne de repli (RI1b) : catégorie `.general`, voir `WebSearchingAction`.
/// Sans chaîne, SearXNG seul, comme avant.
struct WebSearchAction: WebSearchingAction {
    let name = "webSearch"
    let descriptionForPlanner = "Recherche web générale : à utiliser pour toute question nécessitant des informations à jour ou externes, sans domaine particulier."
    let webSearchCategory: WebSearchCategory = .general
    let webSearchChain: WebSearchChain?

    init(webSearchChain: WebSearchChain? = nil) {
        self.webSearchChain = webSearchChain
    }

    func searchSearXNGOnly(query: String, failoverManager: FailoverManager) async throws -> SearXNGSearchResponse {
        try await failoverManager.search(query: query)
    }
}
