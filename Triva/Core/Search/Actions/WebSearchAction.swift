//
//  WebSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Port de `webSearch.ts` (web) : recherche web générale, sans restriction de
/// catégories ni de moteurs — SearXNG interroge son jeu de moteurs par
/// défaut, exactement comme côté web (`executeSearch` n'y reçoit aucun
/// `searchConfig`, contrairement à `academicSearch.ts`/`socialSearch.ts`).
/// `baseSearch.ts` (web) n'a servi ici qu'à comprendre CETTE forme de
/// requête : le scoring qu'il applique ensuite (`BOOSTED_DOMAINS`,
/// similarité cosinus, dédoublonnage par embedding) est hors scope de 1.2,
/// réservé à `SourceRanker` (1.3) — cette action renvoie les résultats bruts
/// de SearXNG, non triés.
struct WebSearchAction: SearchAction {
    let name = "webSearch"
    let descriptionForPlanner = "Recherche web générale : à utiliser pour toute question nécessitant des informations à jour ou externes, sans domaine particulier."

    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        let response = try await failoverManager.search(query: query)
        return .searchResults(response.results)
    }
}
