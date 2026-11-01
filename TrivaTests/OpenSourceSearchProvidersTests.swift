//
//  OpenSourceSearchProvidersTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/10/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Outils de test (préfixe OSS : ne pas entrer en collision avec ceux de R1)

/// Faux transport HTTP : enregistre les requêtes et répond avec (corps, statut). Aucun appel
/// réseau réel.
nonisolated final class OSSTestRequester: HTTPDataRequesting, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(status: Int = 200, body: String) {
        self.init { _ in (Data(body.utf8), status) }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let (data, status) = try handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

nonisolated func ossThrownError(_ work: () async throws -> Void) async -> (any Error)? {
    do {
        try await work()
        return nil
    } catch {
        return error
    }
}

nonisolated func ossQueryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

/// Espaceur arXiv de test : ne dort jamais, enregistre les durées demandées.
nonisolated final class OSSFakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var recordedDelays: [Duration] = []

    var delays: [Duration] { lock.withLock { recordedDelays } }

    func now() -> ContinuousClock.Instant { lock.withLock { instant } }

    func sleep(_ delay: Duration) {
        lock.withLock {
            recordedDelays.append(delay)
            instant = instant + delay
        }
    }

    func makeSpacer(interval: Duration = .seconds(3)) -> ArXivRequestSpacer {
        ArXivRequestSpacer(interval: interval, now: { self.now() }, sleep: { self.sleep($0) })
    }
}

// MARK: - Fixtures

/// Calquée sur une réponse réelle (fr.wikipedia.org, 2026-10-27) : pages DANS LE DÉSORDRE
/// (index 3, 2, 1), une page sans extrait, un « <T> » légitime dans un extrait.
private let wikipediaFixture = """
{
  "batchcomplete": true,
  "continue": { "gsroffset": 4, "continue": "gsroffset||" },
  "query": {
    "pages": [
      {
        "pageid": 12801, "ns": 0, "title": "Gustave Eiffel", "index": 3,
        "extract": "Alexandre Gustave Eiffel est un ingénieur français.\\nIl a dirigé l'entreprise Eiffel.",
        "fullurl": "https://fr.wikipedia.org/wiki/Gustave_Eiffel",
        "canonicalurl": "https://fr.wikipedia.org/wiki/Gustave_Eiffel"
      },
      {
        "pageid": 688954, "ns": 0, "title": "Histoire de la tour Eiffel", "index": 2,
        "extract": "Une classe générique Array<T> existe aussi.",
        "fullurl": "https://fr.wikipedia.org/wiki/Histoire_de_la_tour_Eiffel"
      },
      {
        "pageid": 1359783, "ns": 0, "title": "Tour Eiffel", "index": 1,
        "extract": "La tour Eiffel est une tour autoportante de fer puddlé de 330 m de hauteur.",
        "fullurl": "https://fr.wikipedia.org/wiki/Tour_Eiffel"
      },
      {
        "pageid": 99, "ns": 0, "title": "Page sans extrait", "index": 4,
        "fullurl": "https://fr.wikipedia.org/wiki/Page_sans_extrait"
      }
    ]
  }
}
"""

/// Calquée sur une réponse réelle (api.openalex.org, 2026-10-27, champs de `select`).
private let openAlexFixture = """
{
  "meta": { "count": 3, "page": 1, "per_page": 3 },
  "results": [
    {
      "id": "https://openalex.org/W4387966251",
      "doi": "https://doi.org/10.1109/tvcg.2023.3327163",
      "display_name": "AttentionViz: A Global View of <i>Transformer</i> Attention",
      "publication_year": 2023,
      "abstract_inverted_index": {
        "Transformer": [0], "models": [1, 6], "are": [2], "revolutionizing": [3],
        "machine": [4], "learning": [5], "but": [7], "<jats:italic>opaque</jats:italic>.": [8]
      },
      "primary_location": { "landing_page_url": "https://doi.org/10.1109/tvcg.2023.3327163", "is_oa": false },
      "authorships": [
        { "author": { "id": "A1", "display_name": "Catherine Yeh" } },
        { "author": { "id": "A2", "display_name": "Yida Chen" } },
        { "author": { "id": "A3", "display_name": "Aoyu Wu" } },
        { "author": { "id": "A4", "display_name": "Cynthia Chen" } }
      ]
    },
    {
      "id": "https://openalex.org/W2",
      "doi": null,
      "display_name": "Sans DOI, avec page",
      "abstract_inverted_index": { "Un": [0], "résumé": [1] },
      "primary_location": { "landing_page_url": "https://example.org/papers/2" },
      "authorships": []
    },
    {
      "id": "https://openalex.org/W3",
      "display_name": "Ni DOI ni page, index corrompu",
      "abstract_inverted_index": "ceci n'est pas un index",
      "primary_location": null
    }
  ]
}
"""

/// Calquée sur une réponse réelle (api2.marginalia-search.com, 2026-10-27).
private let marginaliaFixture = """
{
  "license": "CC-BY-NC-SA 4.0", "page": 1, "pages": 11, "query": "swift concurrency",
  "results": [
    {
      "url": "https://cocoacasts.com/collections/mastering-swift-concurrency",
      "title": "Learn Swift and iOS Development",
      "description": "Mastering Swift Concurrency. In the early days of the Swift language, it took just a few hours",
      "quality": 2.94, "format": "html", "resultsFromDomain": 43, "details": [[]]
    },
    {
      "url": "https://www.avanderlee.com/swift/swift-concurrency-course-tutorial-book/",
      "title": "Swift Concurrency \\u0026 Swift 6 Course",
      "description": "Types génériques Box<T> et migration."
    },
    { "title": "Sans URL", "description": "ignoré" }
  ]
}
"""

// MARK: - Wikipédia

@Suite("WikipediaSearchProvider")
struct WikipediaSearchProviderTests {
    @Test("la requête utilise l'API MediaWiki officielle, le bon sous-domaine et le User-Agent")
    func requestShape() async throws {
        let requester = OSSTestRequester(body: wikipediaFixture)
        let provider = WikipediaSearchProvider(requester: requester)
        _ = try await provider.search(query: "tour eiffel", options: WebSearchOptions(language: "fr-FR", maxResults: 5))

        let request = try #require(requester.requests.first)
        #expect(request.url?.host == "fr.wikipedia.org")
        #expect(request.url?.path == "/w/api.php")
        #expect(ossQueryValue("action", in: request) == "query")
        #expect(ossQueryValue("generator", in: request) == "search")
        #expect(ossQueryValue("gsrsearch", in: request) == "tour eiffel")
        #expect(ossQueryValue("gsrlimit", in: request) == "5")
        #expect(ossQueryValue("exlimit", in: request) == "5")
        #expect(ossQueryValue("explaintext", in: request) == "1")
        #expect(ossQueryValue("exintro", in: request) == "1")
        #expect(ossQueryValue("inprop", in: request) == "url")
        #expect(ossQueryValue("formatversion", in: request) == "2")
        #expect(ossQueryValue("maxlag", in: request) == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == OpenSourceSearchHTTP.userAgent)
    }

    @Test("le sous-domaine vient d'une liste blanche : fr pour le français, en sinon",
          arguments: [
            ("fr", "fr.wikipedia.org"), ("FR_ca", "fr.wikipedia.org"), ("en", "en.wikipedia.org"),
            ("de", "en.wikipedia.org"), ("../evil", "en.wikipedia.org"), ("", "en.wikipedia.org"),
          ])
    func hostWhitelist(language: String, expected: String) {
        #expect(WikipediaSearchProvider.host(for: language) == expected)
        #expect(WikipediaSearchProvider.host(for: nil) == "en.wikipedia.org")
    }

    @Test("le nombre de résultats est borné à 1...20")
    func clampsResultCount() throws {
        let provider = WikipediaSearchProvider(requester: OSSTestRequester(body: "{}"))
        let high = try provider.buildRequest(query: "x", options: WebSearchOptions(maxResults: 500))
        let low = try provider.buildRequest(query: "x", options: WebSearchOptions(maxResults: 0))
        #expect(ossQueryValue("gsrlimit", in: high) == "20")
        #expect(ossQueryValue("gsrlimit", in: low) == "1")
    }

    @Test("les pages arrivent dans le désordre : tri sur `index`, URL canonique, texte brut intact")
    func parsesAndOrdersPages() throws {
        let response = try WikipediaSearchProvider.parse(Data(wikipediaFixture.utf8), maxResults: 10)
        #expect(response.results.map(\.title) == [
            "Tour Eiffel", "Histoire de la tour Eiffel", "Gustave Eiffel", "Page sans extrait",
        ])
        #expect(response.results[0].url == "https://fr.wikipedia.org/wiki/Tour_Eiffel")
        // `<T>` légitime d'un extrait en texte brut : ne doit pas être pris pour une balise.
        #expect(response.results[1].content == "Une classe générique Array<T> existe aussi.")
        // Retours à la ligne fusionnés, aucune balise.
        #expect(response.results[2].content == "Alexandre Gustave Eiffel est un ingénieur français. Il a dirigé l'entreprise Eiffel.")
        #expect(response.results[3].content == nil)
        #expect(response.suggestions.isEmpty)
    }

    @Test("maxResults plafonne la liste renvoyée")
    func capsResults() throws {
        let response = try WikipediaSearchProvider.parse(Data(wikipediaFixture.utf8), maxResults: 2)
        #expect(response.results.map(\.title) == ["Tour Eiffel", "Histoire de la tour Eiffel"])
    }

    @Test("aucune clé `query` : réponse vide valide, pas une erreur")
    func noQueryKeyIsEmpty() throws {
        let response = try WikipediaSearchProvider.parse(Data(#"{"batchcomplete":true}"#.utf8), maxResults: 10)
        #expect(response.results.isEmpty)
    }

    @Test("une erreur de l'API en HTTP 200 est traduite")
    func apiErrorEnvelope() {
        let limited = Data(#"{"error":{"code":"ratelimited","info":"x"}}"#.utf8)
        let lagged = Data(#"{"error":{"code":"maxlag","info":"x"}}"#.utf8)
        let other = Data(#"{"error":{"code":"badvalue","info":"x"}}"#.utf8)
        #expect(throws: WebSearchError.rateLimited) { try WikipediaSearchProvider.parse(limited, maxResults: 5) }
        #expect(throws: WebSearchError.unavailable) { try WikipediaSearchProvider.parse(lagged, maxResults: 5) }
        #expect(throws: WebSearchError.invalidResponse) { try WikipediaSearchProvider.parse(other, maxResults: 5) }
    }

    @Test("les trois catégories sont acceptées (Wikipédia ferme la chaîne academic et discussion)",
          arguments: WebSearchCategory.allCases)
    func acceptsEveryCategory(category: WebSearchCategory) async throws {
        let provider = WikipediaSearchProvider(requester: OSSTestRequester(body: wikipediaFixture))
        let response = try await provider.search(query: "tour eiffel", options: WebSearchOptions(category: category))
        #expect(!response.results.isEmpty)
    }

    @Test("requête vide : aucune requête réseau")
    func emptyQueryMakesNoRequest() async throws {
        let requester = OSSTestRequester(body: wikipediaFixture)
        let response = try await WikipediaSearchProvider(requester: requester)
            .search(query: "  \n ", options: WebSearchOptions())
        #expect(response.results.isEmpty)
        #expect(requester.requests.isEmpty)
    }
}

// MARK: - OpenAlex

@Suite("OpenAlexSearchProvider")
struct OpenAlexSearchProviderTests {
    private static let academic = WebSearchOptions(category: .academic, maxResults: 10)

    @Test("la requête cible /works avec search, per_page, select et has_abstract, sans mailto par défaut")
    func requestShape() async throws {
        let requester = OSSTestRequester(body: openAlexFixture)
        _ = try await OpenAlexSearchProvider(requester: requester)
            .search(query: "transformer attention", options: Self.academic)

        let request = try #require(requester.requests.first)
        #expect(request.url?.host == "api.openalex.org")
        #expect(request.url?.path == "/works")
        #expect(ossQueryValue("search", in: request) == "transformer attention")
        #expect(ossQueryValue("per_page", in: request) == "10")
        #expect(ossQueryValue("filter", in: request) == "has_abstract:true")
        #expect(ossQueryValue("select", in: request)?.contains("abstract_inverted_index") == true)
        #expect(ossQueryValue("mailto", in: request) == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == OpenSourceSearchHTTP.userAgent)
    }

    @Test("per_page est borné à 1...100")
    func clampsPerPage() throws {
        let provider = OpenAlexSearchProvider(requester: OSSTestRequester(body: "{}"))
        let high = try provider.buildRequest(query: "x", options: WebSearchOptions(category: .academic, maxResults: 5000))
        let low = try provider.buildRequest(query: "x", options: WebSearchOptions(category: .academic, maxResults: -3))
        #expect(ossQueryValue("per_page", in: high) == "100")
        #expect(ossQueryValue("per_page", in: low) == "1")
    }

    @Test("mailto n'est envoyé que s'il ressemble à une adresse",
          arguments: [("moi@example.org", true), ("  moi@example.org ", true), ("", false), ("   ", false),
                      ("pas-une-adresse", false), ("a@b@c", false), ("@example.org", false), ("a b@c.d", false)])
    func contactEmail(value: String, sent: Bool) throws {
        let provider = OpenAlexSearchProvider(contactEmail: value, requester: OSSTestRequester(body: "{}"))
        let request = try provider.buildRequest(query: "x", options: Self.academic)
        #expect((ossQueryValue("mailto", in: request) != nil) == sent)
    }

    @Test("la clé API part en en-tête Bearer, jamais dans l'URL")
    func apiKeyInHeaderOnly() throws {
        let provider = OpenAlexSearchProvider(apiKey: "oa-secret-1234", requester: OSSTestRequester(body: "{}"))
        let request = try provider.buildRequest(query: "x", options: Self.academic)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oa-secret-1234")
        #expect(request.url?.absoluteString.contains("oa-secret-1234") == false)
        #expect(!String(describing: provider).contains("oa-secret-1234"))
    }

    @Test("les œuvres sont converties : DOI prioritaire, repli page puis id, HTML retiré, auteurs")
    func parsesWorks() throws {
        let response = try OpenAlexSearchProvider.parse(Data(openAlexFixture.utf8), maxResults: 10)
        #expect(response.results.count == 3)

        let first = response.results[0]
        #expect(first.title == "AttentionViz: A Global View of Transformer Attention")
        #expect(first.url == "https://doi.org/10.1109/tvcg.2023.3327163")
        #expect(first.content == "Transformer models are revolutionizing machine learning models but opaque.")
        #expect(first.author == "Catherine Yeh, Yida Chen, Aoyu Wu et al.")

        #expect(response.results[1].url == "https://example.org/papers/2")
        #expect(response.results[1].content == "Un résumé")
        #expect(response.results[1].author == nil)

        // Index corrompu : l'œuvre est gardée, sans résumé ; repli sur l'id OpenAlex.
        #expect(response.results[2].url == "https://openalex.org/W3")
        #expect(response.results[2].content == nil)
    }

    @Test("un DOI sans schéma est préfixé")
    func bareDOI() throws {
        let body = #"{"results":[{"id":"https://openalex.org/W9","doi":"10.1/abc","display_name":"T"}]}"#
        let response = try OpenAlexSearchProvider.parse(Data(body.utf8), maxResults: 3)
        #expect(response.results.first?.url == "https://doi.org/10.1/abc")
    }

    @Test("reconstruction : ordre, doublons, trous, positions négatives, index vide")
    func reconstructsAbstract() {
        let shuffled: [String: [Int]] = ["monde": [1], "Bonjour": [0], "!": [3], "le": [1]]
        // Position 1 portée par deux mots (« le », « monde ») : ordre alphabétique, déterministe.
        #expect(OpenAlexSearchProvider.reconstructAbstract(shuffled) == "Bonjour le monde !")
        #expect(OpenAlexSearchProvider.reconstructAbstract(["a": [0, 5], "b": [2], "c": [-4]]) == "a b a")
        #expect(OpenAlexSearchProvider.reconstructAbstract([:]) == nil)
        #expect(OpenAlexSearchProvider.reconstructAbstract(["x": [-1]]) == nil)
    }

    @Test("les signes < et > littéraux d'un résumé sont conservés, seules les balises sont retirées")
    func keepsLiteralComparisons() {
        let index: [String: [Int]] = [
            "p": [0], "<": [1], "0.05": [2], "and": [3], "n": [4], ">": [5], "30": [6], "<i>x</i>": [7],
        ]
        #expect(OpenAlexSearchProvider.reconstructAbstract(index) == "p < 0.05 and n > 30 x")
        #expect(OpenAlexSearchProvider.cleanMarkup("H<sub>2</sub>O &amp; <i>E. coli</i>") == "H2O & E. coli")
    }

    @Test("une position gigantesque ne provoque aucune allocation proportionnelle")
    func sparseHugePosition() {
        let result = OpenAlexSearchProvider.reconstructAbstract(["début": [0], "fin": [10_000_000]])
        #expect(result == "début fin")
    }

    @Test("le résumé est plafonné à une frontière de mot")
    func truncatesLongAbstract() throws {
        let words = (0..<2000).reduce(into: [String: [Int]]()) { $0["mot\($1)"] = [$1] }
        let text = try #require(OpenAlexSearchProvider.reconstructAbstract(words))
        #expect(text.count <= OpenAlexSearchProvider.abstractCharacterLimit + 1)
        #expect(text.hasSuffix("…"))
        #expect(!text.dropLast().hasSuffix(" "))
    }

    @Test("les catégories general et discussion ne sont pas prises en charge",
          arguments: [WebSearchCategory.general, .discussion])
    func unsupportedCategories(category: WebSearchCategory) async {
        let requester = OSSTestRequester(body: openAlexFixture)
        let error = await ossThrownError {
            _ = try await OpenAlexSearchProvider(requester: requester)
                .search(query: "x", options: WebSearchOptions(category: category))
        }
        #expect(error as? WebSearchError == .unsupportedCategory)
        #expect(requester.requests.isEmpty)
    }

    @Test("statuts HTTP : sans clé, 403 n'accuse jamais une clé ; avec clé, il la refuse")
    func statusMapping() async {
        func thrown(status: Int, apiKey: String?) async -> WebSearchError? {
            let requester = OSSTestRequester(status: status, body: "{}")
            let error = await ossThrownError {
                _ = try await OpenAlexSearchProvider(apiKey: apiKey, requester: requester)
                    .search(query: "x", options: Self.academic)
            }
            return error as? WebSearchError
        }
        #expect(await thrown(status: 429, apiKey: nil) == .rateLimited)
        #expect(await thrown(status: 403, apiKey: nil) == .unavailable)
        #expect(await thrown(status: 503, apiKey: nil) == .unavailable)
        #expect(await thrown(status: 403, apiKey: "k") == .unauthorized)
        #expect(await thrown(status: 429, apiKey: "k") == .rateLimited)
    }
}

// MARK: - Marginalia

@Suite("MarginaliaSearchProvider")
struct MarginaliaSearchProviderTests {
    @Test("la requête cible api2.marginalia-search.com avec la clé publique documentée en en-tête")
    func requestShape() async throws {
        let requester = OSSTestRequester(body: marginaliaFixture)
        _ = try await MarginaliaSearchProvider(requester: requester)
            .search(query: "swift concurrency", options: WebSearchOptions(maxResults: 7))

        let request = try #require(requester.requests.first)
        #expect(request.url?.host == "api2.marginalia-search.com")
        #expect(request.url?.path == "/search")
        #expect(ossQueryValue("query", in: request) == "swift concurrency")
        #expect(ossQueryValue("count", in: request) == "7")
        #expect(ossQueryValue("dc", in: request) == "2")
        #expect(ossQueryValue("nsfw", in: request) == "1")
        #expect(request.value(forHTTPHeaderField: "API-Key") == "public")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == OpenSourceSearchHTTP.userAgent)
        // La clé n'est jamais dans l'URL.
        #expect(request.url?.absoluteString.contains("public") == false)
    }

    @Test("count est borné à 1...100")
    func clampsCount() throws {
        let provider = MarginaliaSearchProvider(requester: OSSTestRequester(body: "{}"))
        let high = try provider.buildRequest(query: "x", options: WebSearchOptions(maxResults: 1000))
        let low = try provider.buildRequest(query: "x", options: WebSearchOptions(maxResults: 0))
        #expect(ossQueryValue("count", in: high) == "100")
        #expect(ossQueryValue("count", in: low) == "1")
    }

    @Test("un + littéral de la requête est encodé en %2B")
    func plusIsEncoded() throws {
        let provider = MarginaliaSearchProvider(requester: OSSTestRequester(body: "{}"))
        let request = try provider.buildRequest(query: "C++ templates", options: WebSearchOptions())
        #expect(request.url?.absoluteString.contains("C%2B%2B") == true)
    }

    @Test("décodage : résultats sans URL ignorés, échappements JSON et <T> préservés")
    func parsesResults() throws {
        let response = try MarginaliaSearchProvider.parse(Data(marginaliaFixture.utf8), maxResults: 10)
        #expect(response.results.count == 2)
        #expect(response.results[0].url == "https://cocoacasts.com/collections/mastering-swift-concurrency")
        #expect(response.results[1].title == "Swift Concurrency & Swift 6 Course")
        #expect(response.results[1].content == "Types génériques Box<T> et migration.")
    }

    @Test("pas de `results` : réponse vide valide ; JSON illisible : réponse invalide")
    func emptyAndInvalid() {
        #expect((try? MarginaliaSearchProvider.parse(Data("{}".utf8), maxResults: 5))?.results.isEmpty == true)
        #expect(throws: WebSearchError.invalidResponse) {
            try MarginaliaSearchProvider.parse(Data("<html>".utf8), maxResults: 5)
        }
    }

    @Test("general et discussion sont acceptées, academic non", arguments: WebSearchCategory.allCases)
    func categories(category: WebSearchCategory) async {
        let requester = OSSTestRequester(body: marginaliaFixture)
        let error = await ossThrownError {
            _ = try await MarginaliaSearchProvider(requester: requester)
                .search(query: "swift", options: WebSearchOptions(category: category))
        }
        if category == .academic {
            #expect(error as? WebSearchError == .unsupportedCategory)
            #expect(requester.requests.isEmpty)
        } else {
            #expect(error == nil)
        }
    }

    @Test("statuts HTTP : 429 et 503 = limite de débit de la clé publique, 403 = indisponible")
    func statusMapping() async {
        let expectations: [(Int, WebSearchError)] = [
            (429, .rateLimited), (503, .rateLimited), (403, .unavailable), (500, .unavailable), (408, .timeout),
        ]
        for (status, expected) in expectations {
            let requester = OSSTestRequester(status: status, body: "")
            let error = await ossThrownError {
                _ = try await MarginaliaSearchProvider(requester: requester)
                    .search(query: "swift", options: WebSearchOptions())
            }
            #expect(error as? WebSearchError == expected)
        }
    }

    @Test("requête vide : aucune requête réseau")
    func emptyQueryMakesNoRequest() async throws {
        let requester = OSSTestRequester(body: marginaliaFixture)
        let response = try await MarginaliaSearchProvider(requester: requester)
            .search(query: "", options: WebSearchOptions())
        #expect(response.results.isEmpty)
        #expect(requester.requests.isEmpty)
    }
}

