//
//  WikipediaSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation

/// Source de recherche Wikipédia (API MediaWiki officielle, aucune clé).
///
/// Sources officielles (consultées le 2026-10-27) :
/// - https://www.mediawiki.org/wiki/API:Search (recherche, `srsearch`/`gsrsearch`)
/// - https://www.mediawiki.org/wiki/Extension:TextExtracts (`exintro`, `explaintext`,
///   `exchars` ≤ 1200, `exlimit` ≤ 20, plusieurs extraits seulement avec `exintro`)
/// - https://www.mediawiki.org/wiki/API:Etiquette et la politique User-Agent de Wikimedia
///
/// Requête : UNE seule requête `GET https://{fr|en}.wikipedia.org/w/api.php` avec
/// `action=query&generator=search&prop=extracts|info`. Le générateur `search` exécute la
/// recherche et `extracts` renvoie, pour chaque page, l'introduction en TEXTE BRUT : pas de
/// balises `<span class="searchmatch">` à nettoyer, et un vrai résumé plutôt que le fragment
/// de 2 lignes que renvoie `list=search`. `info` + `inprop=url` donne l'URL canonique
/// (`fullurl`), donc aucune URL n'est reconstruite à la main (accents, espaces, `/` dans un titre).
///
/// PIÈGE : avec un générateur, `query.pages` n'est PAS dans l'ordre de pertinence. Chaque page
/// porte un champ `index` (rang dans la recherche) ; on trie dessus.
///
/// Choix :
/// - Langue : `fr` si le code demandé est français, sinon `en`. Le sous-domaine vient d'une liste
///   blanche (`host(for:)`) : le code de langue n'est jamais interpolé dans l'hôte.
/// - Les trois catégories sont acceptées. Wikipédia n'est la source « naturelle » que de
///   `general`, mais la chaîne `OpenSourceSearchChain` l'utilise aussi en dernier recours des
///   catégories `academic` et `discussion` : lever `.unsupportedCategory` ici la rendrait
///   inutilisable pile là où on compte sur elle.
/// - Pas de `maxlag` : la doc le réserve aux tâches non interactives, or un utilisateur attend.
/// - 20 résultats maximum : plafond de `exlimit` avec `exintro`.
/// - Extrait plafonné à 1 000 caractères (plafond de l'API : 1 200) : suffisant pour le contexte,
///   sans gonfler le prompt de 20 articles entiers.
///
/// Erreurs : l'API MediaWiki répond souvent en HTTP 200 avec un objet `error` ; on le lit
/// (`ratelimited` -> `.rateLimited`, `maxlag`/`readonly` -> `.unavailable`).
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search` (décodage hors du main actor).
nonisolated struct WikipediaSearchProvider: WebSearchProviding {
    static let path = "/w/api.php"
    static let maxResultsLimit = 20
    static let extractCharacterLimit = 1000

    /// Langues prises en charge -> sous-domaine. Liste blanche : aucune autre valeur n'atteint l'URL.
    static let hosts: [String: String] = ["fr": "fr.wikipedia.org", "en": "en.wikipedia.org"]

    let kind: WebSearchSourceKind = .wikipedia

    private let requester: any HTTPDataRequesting

    init(requester: any HTTPDataRequesting = URLSessionDataRequester()) {
        self.requester = requester
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard BYOKSearchHTTP.trimmedQuery(query) != nil else { return BYOKSearchHTTP.emptyResponse }

        let request = try buildRequest(query: query, options: options)
        let data = try await BYOKSearchHTTP.send(request, via: requester, classify: OpenSourceSearchHTTP.classifyKeyless)
        return try Self.parse(data, maxResults: options.maxResults)
    }

    // MARK: - Requête

    func buildRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        let count = BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxResultsLimit)
        let items = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: BYOKSearchHTTP.trimmedQuery(query) ?? query),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "gsrlimit", value: String(count)),
            URLQueryItem(name: "prop", value: "extracts|info"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exchars", value: String(Self.extractCharacterLimit)),
            URLQueryItem(name: "exlimit", value: String(count)),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "utf8", value: "1"),
        ]
        let url = try BYOKSearchHTTP.makeURL(host: Self.host(for: options.language), path: Self.path, queryItems: items)
        return OpenSourceSearchHTTP.makeRequest(url: url, accept: "application/json")
    }

    /// « fr », « fr-FR », « FR_ca » -> `fr.wikipedia.org` ; tout le reste (y compris `nil`) -> `en`.
    static func host(for language: String?) -> String {
        let base = BYOKSearchHTTP.baseLanguage(from: language) ?? "en"
        return hosts[base] ?? "en.wikipedia.org"
    }

    // MARK: - Réponse

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let decoded = try BYOKSearchHTTP.decode(Envelope.self, from: data)
        if let error = decoded.error { throw mapAPIError(code: error.code) }

        // Pas de clé `query` quand la recherche ne donne rien : réponse vide valide.
        let pages = decoded.query?.pages ?? []
        let ranked = pages.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.index ?? Int.max, rhs.element.index ?? Int.max)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)

        let results = ranked.compactMap { page in
            BYOKSearchHTTP.makeResult(
                title: page.title,
                url: page.fullurl ?? page.canonicalurl,
                // Texte brut demandé (`explaintext`) : surtout pas de `stripHTML`, qui avalerait
                // un « <T> » légitime d'un article sur les génériques.
                content: page.extract
            )
        }
        return SearXNGSearchResponse(results: Array(results.prefix(max(1, maxResults))), suggestions: [])
    }

    private static func mapAPIError(code: String?) -> WebSearchError {
        switch code {
        case "ratelimited": .rateLimited
        case "maxlag", "readonly": .unavailable
        default: .invalidResponse
        }
    }

    // MARK: - Formats JSON (champs utiles seulement)

    nonisolated private struct Envelope: Decodable {
        let error: APIError?
        let query: QueryBody?
    }

    nonisolated private struct APIError: Decodable {
        let code: String?
    }

    nonisolated private struct QueryBody: Decodable {
        let pages: [Page]?
    }

    nonisolated private struct Page: Decodable {
        let title: String?
        let index: Int?
        let extract: String?
        let fullurl: String?
        let canonicalurl: String?
    }
}
