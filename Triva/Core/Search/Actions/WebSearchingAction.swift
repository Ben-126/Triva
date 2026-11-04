//
//  WebSearchingAction.swift
//  Triva
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation

/// Action de recherche web du tour seedé : générale (`WebSearchAction`), académique
/// (`AcademicSearchAction`) ou forums (`SocialSearchAction`). Elle dit en plus QUELLE source a
/// répondu (mission RI1b), ce que `SearchActionOutput` ne sait pas porter.
///
/// Deux chemins, choisis par la présence d'une chaîne de repli :
/// - `webSearchChain` fourni (l'app : `SearchSession` -> `ChatViewModel` -> orchestrateur) : la
///   chaîne complète (`WebSearchChain`), dans la catégorie de l'action ;
/// - `nil` (défaut) : SearXNG seul, via le `FailoverManager` de la session. C'est le comportement
///   d'avant la chaîne, appel pour appel (`searchSearXNGOnly`), que les tests existants
///   verrouillent (moteurs forcés, nombre d'appels, erreurs `FailoverError`).
///
/// `execute`, l'exigence de `SearchAction`, est fourni ici pour les trois actions : il rend les
/// seuls résultats. `searchWeb` rend aussi la source ; c'est lui qu'appelle l'orchestrateur
/// (`SearchOrchestrator.seededWebSearch`).
///
/// Isolé au main actor comme `SearchAction` (protocole non annoté) : la chaîne (`@concurrent`) et
/// le `FailoverManager` (acteur) font leur travail hors du main actor, l'action ne fait qu'aiguiller.
protocol WebSearchingAction: SearchAction {
    /// Catégorie demandée à la chaîne de repli.
    var webSearchCategory: WebSearchCategory { get }

    /// Chaîne de repli de l'envoi, `nil` = SearXNG seul.
    var webSearchChain: WebSearchChain? { get }

    /// Chemin sans chaîne : SearXNG seul, avec les moteurs propres à l'action.
    func searchSearXNGOnly(query: String, failoverManager: FailoverManager) async throws -> SearXNGSearchResponse
}

extension WebSearchingAction {
    /// Résultats et source qui les a fournis.
    ///
    /// Sans chaîne, la source vaut `.searxng` même pour une réponse vide : une recherche a eu
    /// lieu, et c'est SearXNG qui a répondu. Avec la chaîne : `maxResultsPerSource` résultats par
    /// source, comme le chemin historique (page SearXNG entière), et aucune langue imposée ici :
    /// `WebSearchChain` détecte celle de la question pour les sources qui en ont besoin.
    func searchWeb(query: String, failoverManager: FailoverManager) async throws -> WebSearchChainResult {
        guard let webSearchChain else {
            let response = try await searchSearXNGOnly(query: query, failoverManager: failoverManager)
            return WebSearchChainResult(response: response, source: .searxng)
        }
        let options = WebSearchOptions(category: webSearchCategory, maxResults: WebSearchChain.maxResultsPerSource)
        return try await webSearchChain.search(query: query, options: options)
    }

    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        .searchResults(try await searchWeb(query: query, failoverManager: failoverManager).response.results)
    }
}
