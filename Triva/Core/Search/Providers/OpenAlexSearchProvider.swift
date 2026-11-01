//
//  OpenAlexSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation

/// Source de recherche académique OpenAlex (catalogue ouvert d'œuvres scientifiques).
///
/// Sources officielles (consultées le 2026-10-27) :
/// - https://help.openalex.org/how-to-use-the-api/api-overview
/// - https://help.openalex.org/api-entities/works/search-works (`search=`)
/// - https://help.openalex.org/api-entities/works/work-object (`abstract_inverted_index`)
/// - https://help.openalex.org/api/authentication/ (limites, `api_key`, statuts 403/429)
///
/// Requête : `GET https://api.openalex.org/works?search=…&per_page=…&filter=has_abstract:true
/// &select=…`. `select` limite la réponse aux sept champs utiles : sans lui, chaque œuvre
/// embarque des dizaines de champs (références, affiliations, topics…) et la réponse pèse
/// plusieurs centaines de Ko pour rien. `has_abstract:true` écarte les œuvres sans résumé :
/// sans texte, un résultat ne peut ni être cité de façon utile ni nourrir le prompt.
///
/// ABSTRACT : OpenAlex ne fournit pas de texte brut mais un INDEX INVERSÉ
/// (`{"Despite":[0],"growing":[1],…}`, mot -> positions). `reconstructAbstract` le remet à
/// l'endroit en triant des couples (position, mot) : jamais de tableau dense dimensionné sur
/// la plus grande position, car un index mal formé (`10_000_000`) allouerait une mémoire folle.
/// Le texte passe ensuite par `stripHTML` : titres et mots portent parfois du JATS/HTML
/// (`<i>`, `<sub>`, `<jats:p>`).
///
/// URL du résultat, par ordre de préférence : `doi` (identifiant stable, citable), puis
/// `primary_location.landing_page_url`, puis `id` (page OpenAlex).
///
/// LIMITES CONSTATÉES LE 2026-10-27 (voir le rapport) :
/// - sans clé, le budget gratuit est d'environ 0,10 $/jour PARTAGÉ par toutes les machines
///   derrière la même IP ; une recherche coûte 0,001 $, soit ~100 recherches par jour. Au-delà,
///   OpenAlex répond 429 -> `.rateLimited` et la chaîne passe à arXiv puis Wikipédia ;
/// - le paramètre `mailto` / la « polite pool » n'apparaît plus dans l'aide actuelle (elle ne
///   parle que de `api_key`). On le garde, optionnel et vide par défaut, car il était la
///   méthode documentée et reste inoffensif ; aucune garantie qu'il soit encore pris en compte ;
/// - `apiKey` (clé gratuite OpenAlex, 10× le budget) est donc prévue, optionnelle, envoyée en
///   en-tête `Authorization: Bearer` (jamais dans l'URL). Aucun écran de Réglages ne la propose
///   pour l'instant : c'est du ressort de l'intégration.
///
/// Catégorie : seule `.academic` est prise en charge ; les autres lèvent `.unsupportedCategory`.
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search`.
nonisolated struct OpenAlexSearchProvider: WebSearchProviding {
    static let host = "api.openalex.org"
    static let path = "/works"
    /// Maximum documenté de `per_page`.
    static let maxPerPage = 100
    static let selectedFields = "id,doi,display_name,publication_year,abstract_inverted_index,primary_location,authorships"
    /// Plafond du résumé injecté dans le prompt : au-delà de ~2 000 caractères, le surplus
    /// (souvent des mots-clés ou des sections collés par l'éditeur) n'apporte plus rien.
    static let abstractCharacterLimit = 2000
    /// Nombre d'auteurs nommés avant « et al. ».
    static let maxNamedAuthors = 3

    let kind: WebSearchSourceKind = .openAlex

    private let contactEmail: String?
    private let apiKey: SearchSecret?
    private let requester: any HTTPDataRequesting

    /// - Parameters:
    ///   - contactEmail: transmis en `mailto` s'il ressemble à une adresse ; `nil` par défaut.
    ///   - apiKey: clé gratuite OpenAlex, optionnelle.
    init(
        contactEmail: String? = nil,
        apiKey: String? = nil,
        requester: any HTTPDataRequesting = URLSessionDataRequester()
    ) {
        self.contactEmail = Self.cleanedEmail(contactEmail)
        let secret = apiKey.map(SearchSecret.init)
        self.apiKey = (secret?.isEmpty ?? true) ? nil : secret
        self.requester = requester
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard options.category == .academic else { throw WebSearchError.unsupportedCategory }
        guard BYOKSearchHTTP.trimmedQuery(query) != nil else { return BYOKSearchHTTP.emptyResponse }

        let request = try buildRequest(query: query, options: options)
        let usedKey = apiKey != nil
        let data = try await BYOKSearchHTTP.send(request, via: requester) { status, body in
            Self.classify(status: status, body: body, usedKey: usedKey)
        }
        return try Self.parse(data, maxResults: options.maxResults)
    }

    // MARK: - Requête

    func buildRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        let count = BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxPerPage)
        var items = [
            URLQueryItem(name: "search", value: BYOKSearchHTTP.trimmedQuery(query) ?? query),
            URLQueryItem(name: "per_page", value: String(count)),
            URLQueryItem(name: "filter", value: "has_abstract:true"),
            URLQueryItem(name: "select", value: Self.selectedFields),
        ]
        if let contactEmail {
            items.append(URLQueryItem(name: "mailto", value: contactEmail))
        }

        let url = try BYOKSearchHTTP.makeURL(host: Self.host, path: Self.path, queryItems: items)
        var request = OpenSourceSearchHTTP.makeRequest(url: url, accept: "application/json")
        if let apiKey {
            request.setValue("Bearer \(apiKey.value)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Une adresse e-mail plausible (un `@` entouré de texte, sans espace), sinon `nil`.
    private static func cleanedEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace)
        else { return nil }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? trimmed : nil
    }

    // MARK: - Réponse

    /// 429 : budget quotidien ou débit dépassé. 403 : clé non activée (`key_not_activated`) si
    /// une clé a été envoyée -> `.unauthorized` ; sans clé, `.unavailable` (voir
    /// `OpenSourceSearchHTTP.classifyKeyless`).
    static func classify(status: Int, body: Data, usedKey: Bool) -> WebSearchError {
        if usedKey, status == 401 || status == 403 { return .unauthorized }
        return OpenSourceSearchHTTP.classifyKeyless(status: status, body: body)
    }

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let decoded = try BYOKSearchHTTP.decode(Envelope.self, from: data)
        let results = (decoded.results ?? []).compactMap(makeResult(from:))
        return SearXNGSearchResponse(results: Array(results.prefix(max(1, maxResults))), suggestions: [])
    }

    private static func makeResult(from work: Work) -> SearXNGSearchResult? {
        let abstract = work.abstractInvertedIndex.flatMap(reconstructAbstract)
        guard let base = BYOKSearchHTTP.makeResult(
            title: (work.displayName ?? work.title).map(cleanMarkup),
            url: resultURL(for: work),
            content: abstract
        ) else { return nil }

        return SearXNGSearchResult(
            title: base.title,
            url: base.url,
            content: base.content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: authorLine(from: work.authorships ?? []),
            iframeSrc: nil
        )
    }

    private static func resultURL(for work: Work) -> String? {
        if let doi = work.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty {
            return doi.lowercased().hasPrefix("http") ? doi : "https://doi.org/\(doi)"
        }
        if let landing = work.primaryLocation?.landingPageURL, !landing.isEmpty { return landing }
        return work.id
    }

    private static func authorLine(from authorships: [Authorship]) -> String? {
        let names = authorships
            .compactMap { $0.author?.displayName.map(BYOKSearchHTTP.collapseWhitespace) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(maxNamedAuthors).joined(separator: ", ")
        return names.count > maxNamedAuthors ? "\(shown) et al." : shown
    }

    // MARK: - Résumé

    /// Remet à l'endroit un `abstract_inverted_index` (mot -> positions).
    ///
    /// Tolérances : positions dupliquées (les deux mots sont gardés, triés par position puis par
    /// ordre alphabétique pour rester déterministe), trous (ignorés), positions négatives
    /// (ignorées), index vide (`nil`). Le texte est nettoyé du HTML, plafonné à
    /// `abstractCharacterLimit` caractères à une frontière de mot.
    static func reconstructAbstract(_ index: [String: [Int]]) -> String? {
        // Étapes séparées et typées : l'enchaînement flatMap/sorted en une expression dépasse
        // le délai du vérificateur de types.
        var placed: [(position: Int, word: String)] = []
        for (word, positions) in index {
            for position in positions where position >= 0 {
                placed.append((position: position, word: word))
            }
        }
        guard !placed.isEmpty else { return nil }

        placed.sort { (lhs: (position: Int, word: String), rhs: (position: Int, word: String)) -> Bool in
            lhs.position == rhs.position ? lhs.word < rhs.word : lhs.position < rhs.position
        }
        let words: [String] = placed.map { $0.word }

        let text = cleanMarkup(words.joined(separator: " "))
        guard !text.isEmpty else { return nil }
        return truncated(text, to: abstractCharacterLimit)
    }

    /// Retire les VRAIES balises (JATS, `<i>`, `<sub>`…) sans toucher aux signes < et > littéraux.
    ///
    /// Piège : `BYOKSearchHTTP.stripHTML` supprime tout ce qui va d'un `<` au `>` suivant. Sur
    /// « risque réduit (p < 0.05) chez les patients de > 65 ans » il effacerait « < 0.05) chez
    /// les patients de > » — or les comparaisons sont fréquentes dans les résumés médicaux et
    /// statistiques. Ici : (1) on retire les balises, c'est-à-dire un `<` suivi d'une lettre ou
    /// de `/` ; (2) on met les `<` et `>` restants sous forme d'entités ; (3) `stripHTML` n'a
    /// alors plus rien à retirer et décode les entités, ce qui rend les signes d'origine.
    static func cleanMarkup(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(of: "</?[A-Za-z][^<>]*>", with: "", options: .regularExpression)
        let escaped = withoutTags
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return BYOKSearchHTTP.stripHTML(escaped)
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut + "…"
    }

    // MARK: - Formats JSON (champs utiles seulement)

    nonisolated private struct Envelope: Decodable {
        let results: [Work]?
    }

    /// Décodage tolérant : un champ de forme inattendue (par ex. un index inversé corrompu) ne
    /// doit faire perdre ni la réponse entière ni les autres champs de l'œuvre.
    nonisolated private struct Work: Decodable {
        let id: String?
        let doi: String?
        let displayName: String?
        let title: String?
        let abstractInvertedIndex: [String: [Int]]?
        let primaryLocation: Location?
        let authorships: [Authorship]?

        enum CodingKeys: String, CodingKey {
            case id, doi, title, authorships
            case displayName = "display_name"
            case abstractInvertedIndex = "abstract_inverted_index"
            case primaryLocation = "primary_location"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            doi = try? container.decodeIfPresent(String.self, forKey: .doi)
            displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            abstractInvertedIndex = try? container.decodeIfPresent([String: [Int]].self, forKey: .abstractInvertedIndex)
            primaryLocation = try? container.decodeIfPresent(Location.self, forKey: .primaryLocation)
            authorships = try? container.decodeIfPresent([Authorship].self, forKey: .authorships)
        }
    }

    nonisolated private struct Location: Decodable {
        let landingPageURL: String?

        enum CodingKeys: String, CodingKey {
            case landingPageURL = "landing_page_url"
        }
    }

    nonisolated private struct Authorship: Decodable {
        let author: Author?
    }

    nonisolated private struct Author: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }
}
