//
//  MarginaliaSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation

/// Source de recherche Marginalia (moteur indépendant, favorise le web non commercial :
/// blogs, sites personnels, documentation).
///
/// Source officielle (consultée le 2026-10-27) : https://about.marginalia-search.com/article/api/
///
/// Requête : `GET https://api2.marginalia-search.com/search?query=…&count=…&dc=2&nsfw=1` avec
/// l'en-tête `API-Key: public`. `api2.marginalia-search.com` est le point d'accès actuel ;
/// l'ancien (`api.marginalia.nu/{clé}/search/{requête}`) est déclaré obsolète. Réponse :
/// `{"results":[{"url","title","description",…}]}` — vérifiée par un appel réel le 2026-10-27.
///
/// CLÉ `public` : clé de démonstration documentée, partagée par tous ses utilisateurs, donc
/// « souvent » plafonnée (le manuel le dit). Elle n'est pas un secret : c'est la valeur que la
/// doc invite à utiliser, et elle ne donne accès à rien de personnel.
///
/// Paramètres :
/// - `count` borné à 1…100 (plage documentée) ;
/// - `dc=2` : au plus 2 résultats par domaine, sinon un seul site très bien classé occupe toute
///   la page et les sources citées se ressemblent toutes ;
/// - `nsfw=1` : « réduction expérimentale des résultats extrêmes » (doc). Triva est destinée à
///   l'App Store, où un moteur sans filtre serait un risque de refus ;
/// - la langue n'est pas un paramètre de l'API : `options.language` est ignoré.
///
/// Limite de débit : l'ancienne API répondait 503 quand la clé publique était plafonnée, et la
/// doc de la nouvelle ne précise pas le code. On lit donc 503 ET 429 comme `.rateLimited`
/// (un vrai 503 de panne est classé pareil : dans les deux cas, la chaîne passe à la source
/// suivante, et un nouvel essai plus tard est la bonne réaction).
///
/// Catégories : `.general` et `.discussion`. `.academic` lève `.unsupportedCategory` (Marginalia
/// n'indexe pas la littérature scientifique).
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search`.
nonisolated struct MarginaliaSearchProvider: WebSearchProviding {
    static let host = "api2.marginalia-search.com"
    static let path = "/search"
    /// Clé publique documentée (voir l'en-tête de ce fichier).
    static let publicKey = "public"
    static let maxCount = 100
    static let resultsPerDomain = 2

    let kind: WebSearchSourceKind = .marginalia

    private let requester: any HTTPDataRequesting

    init(requester: any HTTPDataRequesting = URLSessionDataRequester()) {
        self.requester = requester
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard options.category != .academic else { throw WebSearchError.unsupportedCategory }
        guard BYOKSearchHTTP.trimmedQuery(query) != nil else { return BYOKSearchHTTP.emptyResponse }

        let request = try buildRequest(query: query, options: options)
        let data = try await BYOKSearchHTTP.send(request, via: requester, classify: Self.classify)
        return try Self.parse(data, maxResults: options.maxResults)
    }

    // MARK: - Requête

    func buildRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        let count = BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxCount)
        let items = [
            URLQueryItem(name: "query", value: BYOKSearchHTTP.trimmedQuery(query) ?? query),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "dc", value: String(Self.resultsPerDomain)),
            URLQueryItem(name: "nsfw", value: "1"),
        ]
        let url = try BYOKSearchHTTP.makeURL(host: Self.host, path: Self.path, queryItems: items)
        var request = OpenSourceSearchHTTP.makeRequest(url: url, accept: "application/json")
        request.setValue(Self.publicKey, forHTTPHeaderField: "API-Key")
        return request
    }

    // MARK: - Réponse

    static func classify(status: Int, body: Data) -> WebSearchError {
        switch status {
        case 429, 503: .rateLimited
        default: OpenSourceSearchHTTP.classifyKeyless(status: status, body: body)
        }
    }

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let decoded = try BYOKSearchHTTP.decode(Envelope.self, from: data)
        // Titre et description sont du texte brut (pas de HTML) : pas de `stripHTML`, qui
        // retirerait un « <T> » légitime d'un article de programmation.
        let results = (decoded.results ?? []).compactMap { item in
            BYOKSearchHTTP.makeResult(title: item.title, url: item.url, content: item.description)
        }
        return SearXNGSearchResponse(results: Array(results.prefix(max(1, maxResults))), suggestions: [])
    }

    // MARK: - Formats JSON (champs utiles seulement)

    nonisolated private struct Envelope: Decodable {
        let results: [Item]?
    }

    nonisolated private struct Item: Decodable {
        let url: String?
        let title: String?
        let description: String?
    }
}
