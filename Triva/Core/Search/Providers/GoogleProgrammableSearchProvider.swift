//
//  GoogleProgrammableSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 08/10/2026.
//

import Foundation

/// Source de recherche Google Programmable Search Engine (Custom Search JSON API) : clé API
/// ET identifiant de moteur « cx », tous deux fournis par l'utilisateur (BYOK).
///
/// Sources officielles (consultées le 2026-10-27) :
/// - https://developers.google.com/custom-search/v1/using_rest (endpoint, `key`, `cx`, `q`)
/// - https://developers.google.com/custom-search/v1/reference/rest/v1/cse/list (`num` 1…10, `lr`, `hl`)
/// - https://developers.google.com/custom-search/v1/reference/rest/v1/Search (`items[].title/link/snippet`)
/// - https://docs.cloud.google.com/docs/authentication/api-keys-use (en-tête `X-goog-api-key`)
///
/// ATTENTION PRODUIT (à arbitrer par Ben) : la page https://developers.google.com/custom-search/v1/overview
/// indique que « The Custom Search JSON API is closed to new customers » et que les clients
/// existants ont jusqu'au 1er janvier 2027 pour migrer (« service discontinuation on January 1,
/// 2027 »). Cette source ne fonctionnera donc plus après cette date, et un nouvel utilisateur
/// ne peut plus obtenir de clé. Elle est implémentée parce que la mission le demande ; la garder
/// ou non dans les Réglages est un choix de produit (voir le rapport).
///
/// LA CLÉ N'EST JAMAIS DANS L'URL. La documentation Google accepte `?key=` mais précise que
/// l'en-tête `X-goog-api-key` est plus sûr, car l'URL complète se retrouve dans les journaux
/// système et dans `URLError.failingURL`. Vérifié le 2026-10-27 avec une fausse clé : l'API
/// `customsearch.googleapis.com` reconnaît l'en-tête exactement comme le paramètre (même erreur
/// « API key not valid » / `API_KEY_INVALID`, alors que sans clé elle répond « unregistered
/// callers »). En plus, `BYOKSearchHTTP.send` ne relaie jamais l'erreur d'origine : seul un
/// `WebSearchError` à message fixe sort de ce fichier.
///
/// Paramètres :
/// - `num` borné à 1…10 (maximum documenté) ; au-delà il faudrait paginer avec `start`, ce que
///   Triva ne fait pas (une page suffit au pipeline) ;
/// - `lr=lang_xx` (restriction de langue) ET `hl=xx` (langue de l'interface) si une langue est
///   donnée. `lr` est une restriction STRICTE : un résultat dans une autre langue n'est pas
///   renvoyé. À l'appelant de ne passer `options.language` que s'il veut cette restriction (un
///   choix produit à trancher à l'intégration : voir la décision FR+EN de Discover et la limite
///   de classement par langue de `SourceRanker`) ;
/// - les catégories `.academic` et `.discussion` sont traitées comme `.general`, sans lever
///   `.unsupportedCategory` (le moteur « cx » décide lui-même de son périmètre).
///
/// Erreurs : Google répond 400 `INVALID_ARGUMENT` / `API_KEY_INVALID` pour une clé inconnue
/// (observé), 403 pour une clé sans droit ou un quota quotidien dépassé, 429 pour un débit
/// dépassé. Le corps est lu pour distinguer « quota » de « refus » (motifs `rateLimitExceeded`,
/// `dailyLimitExceeded`, `quotaExceeded`, `RATE_LIMIT_EXCEEDED`, `RESOURCE_EXHAUSTED`), mais
/// il n'est JAMAIS recopié dans une erreur ni un message.
///
/// Un autre 400 (« cx » inconnu, requête invalide) donne `.invalidResponse` : le contrat commun
/// n'a pas de cas « moteur invalide ». Les Réglages peuvent l'expliquer ainsi : « vérifie
/// l'identifiant du moteur ».
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search` (voir `ScrapeService`).
nonisolated struct GoogleProgrammableSearchProvider: WebSearchProviding, SearchKeyValidating {
    static let host = "www.googleapis.com"
    static let path = "/customsearch/v1"
    static let maxNum = 10

    let kind: WebSearchSourceKind = .googleProgrammableSearch

    private let apiKey: SearchSecret
    private let engineID: String
    private let requester: any HTTPDataRequesting

    init(
        apiKey: String,
        engineID: String,
        requester: any HTTPDataRequesting = URLSessionDataRequester()
    ) {
        self.apiKey = SearchSecret(apiKey)
        self.engineID = engineID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requester = requester
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard !apiKey.isEmpty, !engineID.isEmpty else { throw WebSearchError.missingKey }
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
        var items = [
            URLQueryItem(name: "cx", value: engineID),
            URLQueryItem(name: "q", value: BYOKSearchHTTP.trimmedQuery(query) ?? query),
            URLQueryItem(name: "num", value: String(BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxNum))),
        ]
        if let language = BYOKSearchHTTP.baseLanguage(from: options.language) {
            items.append(URLQueryItem(name: "lr", value: "lang_\(language)"))
            items.append(URLQueryItem(name: "hl", value: language))
        }

        let url = try BYOKSearchHTTP.makeURL(host: Self.host, path: Self.path, queryItems: items)
        var request = URLRequest(url: url, timeoutInterval: BYOKSearchHTTP.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey.value, forHTTPHeaderField: "X-goog-api-key")
        return request
    }

    // MARK: - Réponse

    static func classify(status: Int, body: Data) -> WebSearchError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        let reasons = envelope?.error?.allReasons ?? []

        if reasons.contains(where: Self.isQuotaReason) { return .rateLimited }
        if reasons.contains("API_KEY_INVALID") || reasons.contains("keyInvalid") { return .unauthorized }
        // Clé inconnue : 400 (observé). Le motif détaillé `API_KEY_INVALID` est testé ci-dessus ;
        // ce repli couvre le message seul, si le détail venait à disparaître.
        if status == 400, envelope?.error?.message?.localizedCaseInsensitiveContains("API key not valid") == true {
            return .unauthorized
        }
        return BYOKSearchHTTP.defaultError(forStatus: status)
    }

    private static func isQuotaReason(_ reason: String) -> Bool {
        ["rateLimitExceeded", "dailyLimitExceeded", "userRateLimitExceeded", "quotaExceeded",
         "RATE_LIMIT_EXCEEDED", "RESOURCE_EXHAUSTED"].contains(reason)
    }

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let decoded = try BYOKSearchHTTP.decode(ResponseBody.self, from: data)
        // `items` est absent quand la recherche ne donne rien : réponse vide valide.
        let results = (decoded.items ?? []).compactMap { item in
            BYOKSearchHTTP.makeResult(title: item.title, url: item.link, content: item.snippet)
        }
        let capped = Array(results.prefix(max(1, maxResults)))
        return SearXNGSearchResponse(results: capped, suggestions: [])
    }

    // MARK: - Formats JSON

    nonisolated private struct ResponseBody: Decodable {
        let items: [Item]?
    }

    nonisolated private struct Item: Decodable {
        let title: String?
        let link: String?
        let snippet: String?
    }

    nonisolated private struct ErrorEnvelope: Decodable {
        let error: ErrorBody?
    }

    /// Les motifs d'erreur se trouvent à deux endroits : `errors[].reason` (ancien format,
    /// `badRequest`, `rateLimitExceeded`…) et `details[].reason` (format `google.rpc.ErrorInfo`,
    /// `API_KEY_INVALID`…). On les réunit.
    nonisolated private struct ErrorBody: Decodable {
        let message: String?
        let errors: [Reason]?
        let details: [Reason]?

        var allReasons: [String] {
            ((errors ?? []) + (details ?? [])).compactMap(\.reason)
        }
    }

    nonisolated private struct Reason: Decodable {
        let reason: String?
    }
}
