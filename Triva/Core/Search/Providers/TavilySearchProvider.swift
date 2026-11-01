//
//  TavilySearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 08/10/2026.
//

import Foundation

/// Source de recherche Tavily (clé personnelle de l'utilisateur, BYOK).
///
/// Source officielle (consultée le 2026-10-27) :
/// https://docs.tavily.com/documentation/api-reference/endpoint/search
///
/// Requête : `POST https://api.tavily.com/search`, en-tête `Authorization: Bearer tvly-…`,
/// corps JSON `{ query, search_depth, topic, max_results, include_answer, language }`.
///
/// Choix de paramètres :
/// - `search_depth = "basic"` PAR DÉFAUT : 1 crédit par requête (« advanced » en coûte 2). Le
///   quota de l'utilisateur est à lui, on ne le double pas sans qu'il l'ait demandé. L'init
///   accepte `.advanced` pour un futur réglage, mais rien ne l'utilise en V1 ;
/// - `topic = "general"` : les catégories `.academic` et `.discussion` y sont aussi traitées
///   (Tavily est généraliste), sans lever `.unsupportedCategory` qui ferait sauter une source
///   qui marche ;
/// - `include_answer = false` : Triva fait sa propre synthèse et ses propres citations. La
///   « réponse » de Tavily serait un texte sans source exploitable ;
/// - `max_results` borné à 1…20 (documenté 0…20, mais 0 ne servirait à rien) ;
/// - `language` : code ISO 639-1 (« fr »), documenté comme simple BONUS de classement (il
///   favorise la langue, il n'exclut rien). Omis si l'appelant n'en donne pas.
///
/// Mapping des résultats : `title`, `url`, `content` -> `SearXNGSearchResult`. Le `content`
/// de Tavily est un extrait recomposé par leur moteur, pas un snippet brut : il convient très
/// bien au prompt, mais n'est pas le texte exact de la page. `score` est ignoré (le classement
/// final est refait par `SourceRanker`).
///
/// Statuts : 401 = clé absente ou invalide ; 429 = trop de requêtes ; 432 = limite de la clé
/// ou du forfait dépassée ; 433 = limite « pay-as-you-go » dépassée. 432 et 433 sont lus comme
/// `.rateLimited` : la clé est reconnue, c'est le quota qui est épuisé.
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search` (voir `ScrapeService`).
nonisolated struct TavilySearchProvider: WebSearchProviding, SearchKeyValidating {
    static let host = "api.tavily.com"
    static let path = "/search"
    static let maxResultsLimit = 20

    /// Profondeur de recherche. `basic` = 1 crédit, `advanced` = 2 crédits (doc Tavily).
    enum Depth: String, Sendable, Equatable {
        case basic
        case advanced
    }

    let kind: WebSearchSourceKind = .tavily

    private let apiKey: SearchSecret
    private let depth: Depth
    private let requester: any HTTPDataRequesting

    init(
        apiKey: String,
        depth: Depth = .basic,
        requester: any HTTPDataRequesting = URLSessionDataRequester()
    ) {
        self.apiKey = SearchSecret(apiKey)
        self.depth = depth
        self.requester = requester
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard !apiKey.isEmpty else { throw WebSearchError.missingKey }
        guard BYOKSearchHTTP.trimmedQuery(query) != nil else { return BYOKSearchHTTP.emptyResponse }

        let request = try buildRequest(query: query, options: options)
        let data = try await BYOKSearchHTTP.send(request, via: requester, classify: Self.classify)
        return try Self.parse(data, maxResults: options.maxResults)
    }

    func validateKey() async throws -> SearchKeyValidationOutcome {
        try await BYOKSearchHTTP.validate(self)
    }

    // MARK: - Requête

    func buildRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        let url = try BYOKSearchHTTP.makeURL(host: Self.host, path: Self.path, queryItems: [])
        let body = RequestBody(
            query: BYOKSearchHTTP.trimmedQuery(query) ?? query,
            searchDepth: depth.rawValue,
            topic: "general",
            maxResults: BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxResultsLimit),
            includeAnswer: false,
            language: BYOKSearchHTTP.baseLanguage(from: options.language)
        )

        var request = URLRequest(url: url, timeoutInterval: BYOKSearchHTTP.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw WebSearchError.invalidResponse
        }
        return request
    }

    // MARK: - Réponse

    static func classify(status: Int, body: Data) -> WebSearchError {
        switch status {
        case 432, 433: .rateLimited
        default: BYOKSearchHTTP.defaultError(forStatus: status)
        }
    }

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let decoded = try BYOKSearchHTTP.decode(ResponseBody.self, from: data)
        let results = (decoded.results ?? []).compactMap { item in
            BYOKSearchHTTP.makeResult(title: item.title, url: item.url, content: item.content)
        }
        let capped = Array(results.prefix(max(1, maxResults)))
        return SearXNGSearchResponse(results: capped, suggestions: [])
    }

    // MARK: - Formats JSON

    nonisolated private struct RequestBody: Encodable {
        let query: String
        let searchDepth: String
        let topic: String
        let maxResults: Int
        let includeAnswer: Bool
        let language: String?

        enum CodingKeys: String, CodingKey {
            case query, topic, language
            case searchDepth = "search_depth"
            case maxResults = "max_results"
            case includeAnswer = "include_answer"
        }
    }

    nonisolated private struct ResponseBody: Decodable {
        let results: [Item]?
    }

    nonisolated private struct Item: Decodable {
        let title: String?
        let url: String?
        let content: String?
    }
}
