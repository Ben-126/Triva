//
//  ArXivSearchProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation

/// Source de recherche académique arXiv (préimpressions en physique, maths, informatique…).
///
/// Source officielle (consultée le 2026-10-27) : manuel de l'API arXiv,
/// https://info.arxiv.org/help/api/user-manual.html
///
/// Requête : `GET https://export.arxiv.org/api/query?search_query=…&start=0&max_results=…
/// &sortBy=relevance&sortOrder=descending`. Le manuel montre `http://` mais le site répond en
/// HTTPS, et App Transport Security interdit le HTTP en clair : on utilise HTTPS.
///
/// Réponse : un flux Atom 1.0, lu avec `XMLParser` (Foundation) — aucune dépendance. Le flux a
/// ses propres `<title>` et `<id>` : le parseur ne retient que ceux situés DANS un `<entry>`.
///
/// CONSTRUCTION DE `search_query` (le piège principal) :
/// - la requête de l'utilisateur est une phrase en langage naturel, pas la syntaxe arXiv
///   (`ti:`, `AND`, guillemets, parenthèses). La passer telle quelle donnerait une erreur ou
///   des résultats absurdes ; on en extrait des MOTS (lettres/chiffres uniquement, donc `:`, `(`,
///   `)`, `"` et `+` disparaissent), on retire les mots vides FR/EN et on garde les 8 premiers ;
/// - chaque mot devient `all:mot`, séparés par une espace. Sans opérateur, arXiv combine en OU
///   (mesuré le 2026-10-27) et `sortBy=relevance` place en tête les articles qui contiennent le
///   plus de termes. Un ET strict renvoyait 0 résultat dès qu'un mot de la question était
///   absent (« what are latest advances transformers » : 0 en ET, plus de 300 000 en OU) ;
/// - l'espace est encodée `%20` par `URLComponents` (le `+` du manuel est une autre notation
///   pour la même chose) ; `BYOKSearchHTTP.makeURL` encode les `+` littéraux.
///
/// ERREURS : arXiv renvoie ses erreurs de requête sous forme de FLUX ATOM valide (statut 200)
/// avec une unique entrée dont l'`<id>` est `http://arxiv.org/api/errors#…` et le titre
/// « Error ». Elle ne doit surtout pas être affichée comme un résultat : -> `.invalidResponse`.
///
/// DÉBIT : le manuel demande 3 secondes entre deux requêtes ; `ArXivRequestSpacer` (partagé par
/// toute l'app) l'impose avant chaque envoi. Le manuel recommande aussi de mettre en cache, ce
/// que fait déjà le pipeline de recherche en amont (une même question n'est pas relancée).
///
/// Catégorie : seule `.academic` est prise en charge (arXiv en `.general` renverrait des
/// articles hors sujet pour une question courante) ; les autres lèvent `.unsupportedCategory`.
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `search`.
nonisolated struct ArXivSearchProvider: WebSearchProviding {
    static let host = "export.arxiv.org"
    static let path = "/api/query"
    static let maxResultsLimit = 50
    static let maxTerms = 8

    let kind: WebSearchSourceKind = .arXiv

    private let requester: any HTTPDataRequesting
    private let spacer: ArXivRequestSpacer

    init(
        requester: any HTTPDataRequesting = URLSessionDataRequester(),
        spacer: ArXivRequestSpacer = .shared
    ) {
        self.requester = requester
        self.spacer = spacer
    }

    @concurrent
    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        guard options.category == .academic else { throw WebSearchError.unsupportedCategory }
        guard Self.searchQuery(from: query) != nil else { return BYOKSearchHTTP.emptyResponse }

        let request = try buildRequest(query: query, options: options)
        // Pause AVANT l'envoi (et non après la réponse) : c'est l'intervalle entre deux
        // requêtes qui compte pour arXiv.
        try await spacer.waitForTurn()
        let data = try await BYOKSearchHTTP.send(request, via: requester, classify: OpenSourceSearchHTTP.classifyKeyless)
        return try Self.parse(data, maxResults: options.maxResults)
    }

    // MARK: - Requête

    func buildRequest(query: String, options: WebSearchOptions) throws -> URLRequest {
        guard let searchQuery = Self.searchQuery(from: query) else { throw WebSearchError.invalidResponse }
        let count = BYOKSearchHTTP.clamp(options.maxResults, to: 1...Self.maxResultsLimit)
        let items = [
            URLQueryItem(name: "search_query", value: searchQuery),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(count)),
            URLQueryItem(name: "sortBy", value: "relevance"),
            URLQueryItem(name: "sortOrder", value: "descending"),
        ]
        let url = try BYOKSearchHTTP.makeURL(host: Self.host, path: Self.path, queryItems: items)
        return OpenSourceSearchHTTP.makeRequest(url: url, accept: "application/atom+xml")
    }

    /// Mots vides français et anglais courants, minuscules. Volontairement courts : l'objectif
    /// est d'éviter qu'un « what are the » ne noie les vrais termes, pas de faire du TAL.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "what", "which", "who", "whom", "whose", "how", "why",
        "are", "was", "were", "is", "of", "in", "on", "to", "a", "an", "about", "from", "that",
        "this", "these", "those", "does", "did", "do", "can", "could", "would", "should", "latest",
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "en", "dans", "sur", "pour",
        "avec", "quel", "quelle", "quels", "quelles", "qui", "que", "quoi", "comment", "pourquoi",
        "est", "sont", "ce", "cette", "ces", "au", "aux", "par", "plus", "sans", "sous",
    ]

    /// Valeur de `search_query` pour une phrase libre, ou `nil` s'il ne reste aucun mot.
    ///
    /// Si la phrase ne contient QUE des mots vides (« what is the »), on les garde plutôt que de
    /// renvoyer `nil` : une requête déjà minuscule n'a rien à perdre.
    static func searchQuery(from query: String) -> String? {
        let words = query
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count > 1 || $0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return nil }

        let meaningful = words.filter { !stopWords.contains($0.lowercased()) }
        let chosen = (meaningful.isEmpty ? words : meaningful).prefix(maxTerms)
        return chosen.map { "all:\($0)" }.joined(separator: " ")
    }

    // MARK: - Réponse

    static func parse(_ data: Data, maxResults: Int) throws -> SearXNGSearchResponse {
        let entries = try ArXivAtomParser.entries(from: data)
        if entries.contains(where: { $0.isErrorEntry }) { throw WebSearchError.invalidResponse }

        let results = entries.compactMap { entry -> SearXNGSearchResult? in
            guard let base = BYOKSearchHTTP.makeResult(
                title: entry.title,
                url: entry.abstractURL,
                content: entry.summary
            ) else { return nil }
            return SearXNGSearchResult(
                title: base.title,
                url: base.url,
                content: base.content,
                imgSrc: nil,
                thumbnailSrc: nil,
                thumbnail: nil,
                author: authorLine(from: entry.authors),
                iframeSrc: nil
            )
        }
        return SearXNGSearchResponse(results: Array(results.prefix(max(1, maxResults))), suggestions: [])
    }

    private static func authorLine(from authors: [String]) -> String? {
        let names = authors.map(BYOKSearchHTTP.collapseWhitespace).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) et al." : shown
    }
}

// MARK: - Lecture du flux Atom

/// Une entrée du flux Atom arXiv, telle que lue (non nettoyée).
nonisolated struct ArXivAtomEntry: Sendable, Equatable {
    var id = ""
    var title = ""
    var summary = ""
    var authors: [String] = []
    var alternateLink: String?

    /// Les erreurs de requête arrivent comme une entrée dont l'id pointe vers `/api/errors`.
    var isErrorEntry: Bool {
        id.lowercased().contains("arxiv.org/api/errors")
    }

    /// Page de résumé de l'article : lien `rel="alternate"`, sinon `<id>`. Toujours en HTTPS :
    /// l'`<id>` renvoyé par arXiv est en `http://`, que ScrapeService ne pourrait pas ouvrir
    /// (App Transport Security).
    var abstractURL: String {
        let raw = (alternateLink ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.lowercased().hasPrefix("http://") ? "https://" + raw.dropFirst("http://".count) : raw
    }
}

/// Lecteur `XMLParser` d'un flux Atom arXiv.
///
/// `XMLParser` de Foundation ne résout pas les entités externes par défaut
/// (`shouldResolveExternalEntities == false`) : pas de vecteur XXE sur une réponse réseau.
/// Les noms d'éléments sont lus avec leur préfixe (`arxiv:comment`, `opensearch:…`) car le
/// traitement des espaces de noms est désactivé ; seuls `entry`, `id`, `title`, `summary`,
/// `author`, `name` et `link` nous intéressent.
nonisolated final class ArXivAtomParser: NSObject, XMLParserDelegate {
    private var entries: [ArXivAtomEntry] = []
    private var current: ArXivAtomEntry?
    private var inAuthor = false
    private var buffer = ""

    /// Lit toutes les entrées ; flux illisible -> `.invalidResponse`.
    static func entries(from data: Data) throws -> [ArXivAtomEntry] {
        let delegate = ArXivAtomParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw WebSearchError.invalidResponse }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        buffer = ""
        switch elementName {
        case "entry":
            current = ArXivAtomEntry()
        case "author":
            inAuthor = current != nil
        case "link":
            if current != nil, attributeDict["rel"] == "alternate", let href = attributeDict["href"] {
                current?.alternateLink = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard current != nil else { return }
        switch elementName {
        case "id": current?.id = buffer
        case "title": current?.title = buffer
        case "summary": current?.summary = buffer
        case "name": if inAuthor { current?.authors.append(buffer) }
        case "author": inAuthor = false
        case "entry":
            if let finished = current { entries.append(finished) }
            current = nil
        default: break
        }
        buffer = ""
    }
}
