//
//  BraveSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 08/10/2026.
//

import Foundation

/// Source de recherche Brave Search API (clé personnelle de l'utilisateur, BYOK).
///
/// Sources officielles (consultées le 2026-10-27) :
/// - https://api-dashboard.search.brave.com/app/documentation/web-search/get-started
/// - https://api-dashboard.search.brave.com/api-reference/web/search/get
///
/// Requête : `GET https://api.search.brave.com/res/v1/web/search?q=…&count=…` avec l'en-tête
/// `X-Subscription-Token: <clé>`. Zéro serveur intermédiaire : la clé part de l'appareil vers
/// Brave et nulle part ailleurs.
///
/// Choix de paramètres :
/// - `count` borné à 1…20 (maximum documenté) ;
/// - `search_lang` : uniquement si le code figure dans la liste documentée (`supportedSearchLanguages`).
///   Un code hors liste est refusé par Brave (422) et ferait échouer toute la source : on préfère
///   ne rien envoyer et laisser Brave utiliser sa langue par défaut ;
/// - `text_decorations=false` : pas de balises de surbrillance dans les extraits (on les retire de
///   toute façon par sécurité, voir `BYOKSearchHTTP.stripHTML`) ;
/// - `result_filter=web` : seuls les résultats web sont utiles ici, inutile de payer le transfert
///   des vidéos, forums et infobox ;
/// - les catégories `.academic` et `.discussion` sont traitées comme `.general` : Brave est un
///   moteur web généraliste. Lever `.unsupportedCategory` ferait sauter une source qui marche.
///
/// Écart assumé avec la doc : le statut 422 n'est pas décrit officiellement. Des utilisateurs
/// rapportent qu'un jeton invalide renvoie 422 avec le code `SUBSCRIPTION_TOKEN_INVALID`
/// (forum communautaire Brave) ; on le lit donc comme « clé refusée ». Tout autre 422 est une
/// requête mal formée de notre côté (`.invalidResponse`).
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search` (décodage JSON hors du main actor,
/// voir `ScrapeService`).
nonisolated struct BraveSearchProvider: WebSearchProviding, SearchKeyValidating {
    static let host = "api.search.brave.com"
    static let path = "/res/v1/web/search"
    static let maxCount = 20

    /// Valeurs documentées de `search_lang` (référence API, consultée le 2026-10-27).
    static let supportedSearchLanguages: Set<String> = [
        "ar", "eu", "bn", "bg", "ca", "zh-hans", "zh-hant", "hr", "cs", "da", "nl", "en", "en-gb",
        "et", "fi", "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "is", "it", "ja", "jp", "kn",
        "ko", "lv", "lt", "ms", "ml", "mr", "nb", "pl", "pt-br", "pt-pt", "pa", "ro", "ru", "sr",
        "sk", "sl", "es", "sv", "ta", "te", "th", "tr", "uk", "vi",
    ]

    let kind: WebSearchSourceKind = .braveSearch

    private let apiKey: SearchSecret
    private let requester: any HTTPDataRequesting

    init(apiKey: String, requester: any HTTPDataRequesting = URLSessionDataRequester()) {
        self.apiKey = SearchSecret(apiKey)
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
        let count = BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxCount)
        var items = [
            URLQueryItem(name: "q", value: BYOKSearchHTTP.trimmedQuery(query) ?? query),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "text_decorations", value: "false"),
            URLQueryItem(name: "result_filter", value: "web"),
        ]
        if let language = Self.searchLanguage(for: options.language) {
            items.append(URLQueryItem(name: "search_lang", value: language))
        }

        let url = try BYOKSearchHTTP.makeURL(host: Self.host, path: Self.path, queryItems: items)
        var request = URLRequest(url: url, timeoutInterval: BYOKSearchHTTP.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey.value, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    /// « fr-FR » -> `fr` ; « en-GB » -> `en-gb` ; « pt-BR » -> `pt-br` ; « zh-Hans » -> `zh-hans`.
    /// Cas particuliers : « pt » seul -> `pt-pt` ; « no » -> `nb` ; « zh » -> `zh-hans`.
    /// `nil` si la langue n'est pas prise en charge par Brave.
    static func searchLanguage(for language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
        if supportedSearchLanguages.contains(normalized) { return normalized }
        guard let base = BYOKSearchHTTP.baseLanguage(from: normalized) else { return nil }
        let aliases = ["pt": "pt-pt", "no": "nb", "zh": "zh-hans"]
        let candidate = aliases[base] ?? base
        return supportedSearchLanguages.contains(candidate) ? candidate : nil
    }

    // MARK: - Réponse

    static func classify(status: Int, body: Data) -> WebSearchError {
        switch status {
        case 422:
            return bodyReportsInvalidToken(body) ? .unauthorized : .invalidResponse
        default:
            return BYOKSearchHTTP.defaultError(forStatus: status)
        }
    }

    private static func bodyReportsInvalidToken(_ body: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
              let code = envelope.error?.code
        else { return false }
        return code.uppercased().contains("TOKEN")
    }

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let decoded = try BYOKSearchHTTP.decode(WebResponse.self, from: data)
        // `web` est absent quand la requête ne donne aucun résultat web : réponse vide valide.
        let raw = decoded.web?.results ?? []
        let results = raw.compactMap { item in
            BYOKSearchHTTP.makeResult(
                title: item.title.map(BYOKSearchHTTP.stripHTML),
                url: item.url,
                content: item.description.map(BYOKSearchHTTP.stripHTML)
            )
        }
        let capped = Array(results.prefix(max(1, maxResults)))
        return SearXNGSearchResponse(results: capped, suggestions: [])
    }

    // MARK: - Formats JSON (champs utiles seulement)

    nonisolated private struct WebResponse: Decodable {
        let web: WebSection?
    }

    nonisolated private struct WebSection: Decodable {
        let results: [WebItem]?
    }

    nonisolated private struct WebItem: Decodable {
        let title: String?
        let url: String?
        let description: String?
    }

    nonisolated private struct ErrorEnvelope: Decodable {
        let error: ErrorBody?
    }

    nonisolated private struct ErrorBody: Decodable {
        let code: String?
    }
}
