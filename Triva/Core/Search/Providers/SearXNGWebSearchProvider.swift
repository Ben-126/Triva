//
//  SearXNGWebSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation

/// Adaptateur `WebSearchProviding` (kind `.searxng`) au-dessus de `FailoverManager` : c'est la
/// deuxième maille de la chaîne de repli (après une éventuelle clé de recherche personnelle),
/// avec instances testées et classées par fiabilité.
///
/// TRADUCTION DES OPTIONS — port de la logique de sélection d'actions de la version web d'origine
/// (recherche académique : `engines: ['arxiv', 'google scholar', 'pubmed']` ;
/// recherche sociale : `engines: ['reddit']` ; recherche générale : aucun filtre) :
/// - `.general` : ni catégorie ni moteur forcés, l'instance utilise sa configuration ;
/// - `.academic` : moteurs `arxiv`, `google scholar`, `pubmed` ;
/// - `.discussion` : moteur `reddit`.
/// Les moteurs sont forcés plutôt que la catégorie `science` / `social media` parce que c'est
/// ce que fait la version web d'origine (parité), et qu'une catégorie dépend de la configuration de chaque
/// instance. Écart connu : une instance qui a désactivé ces moteurs renvoie peu ou pas de
/// résultat ; `WebSearchChain` retombe alors sur la source suivante.
///
/// - `language` : transmis tel quel (« fr », « en »), après nettoyage ; SearXNG accepte le code
///   court.
/// - `maxResults` : SearXNG n'a pas de paramètre de taille de page, on tronque la réponse. Les
///   suggestions sont conservées.
/// - Requête vide : réponse vide sans réseau, comme les autres sources.
///
/// TRADUCTION DES ERREURS (contrat `WebSearchError` : messages fixes, rien du serveur) :
/// - aucune instance configurée -> `.unavailable` ;
/// - toutes ont échoué -> `.noConnection` si l'une a vu l'appareil hors ligne, `.timeout` si
///   TOUTES ont expiré, `.rateLimited` si TOUTES ont répondu 429, sinon `.unavailable`.
///   `.invalidResponse` n'est pas utilisé : « aucune instance ne sert du JSON » est, pour
///   l'utilisateur, une source indisponible ;
/// - annulation -> `CancellationError` (jamais convertie, sinon `WebSearchChain` passerait à
///   la source suivante alors que l'utilisateur vient d'appuyer sur Stop).
///
/// CONCURRENCE : `nonisolated` + `@concurrent` ; `FailoverManager` est un acteur, donc `Sendable`.
nonisolated struct SearXNGWebSearchProvider: WebSearchProviding {
    static let academicEngines = ["arxiv", "google scholar", "pubmed"]
    static let discussionEngines = ["reddit"]

    let kind: WebSearchSourceKind = .searxng

    private let failover: FailoverManager

    init(failover: FailoverManager) {
        self.failover = failover
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearXNGSearchResponse(results: [], suggestions: [])
        }

        do {
            let response = try await failover.searchDetailed(
                query: trimmed,
                options: Self.searxngOptions(for: options)
            )
            return Self.truncated(response, to: options.maxResults)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.webSearchError(for: error)
        }
    }

    // MARK: - Traduction

    static func searxngOptions(for options: WebSearchOptions) -> SearXNGSearchOptions {
        let language = options.language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let engines: [String] = switch options.category {
        case .general: []
        case .academic: academicEngines
        case .discussion: discussionEngines
        }
        return SearXNGSearchOptions(
            engines: engines,
            language: language?.isEmpty == false ? language : nil
        )
    }

    static func webSearchError(for error: any Error) -> WebSearchError {
        guard let exhausted = error as? FailoverExhaustedError, !exhausted.reasons.isEmpty else {
            return .unavailable
        }
        if exhausted.deviceOffline { return .noConnection }
        if exhausted.reasons.allSatisfy({ $0 == .timeout }) { return .timeout }
        if exhausted.reasons.allSatisfy({ $0 == .rateLimited }) { return .rateLimited }
        return .unavailable
    }

    private static func truncated(_ response: SearXNGSearchResponse, to maxResults: Int) -> SearXNGSearchResponse {
        let limit = max(1, maxResults)
        guard response.results.count > limit else { return response }
        return SearXNGSearchResponse(results: Array(response.results.prefix(limit)), suggestions: response.suggestions)
    }
}
