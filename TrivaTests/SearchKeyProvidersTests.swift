//
//  SearchKeyProvidersTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 08/10/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Outils de test partagés (R1)

/// Faux transport HTTP : enregistre les requêtes et répond avec (corps, statut) fixés par un
/// gestionnaire. Aucun appel réseau réel. `nonisolated` : le protocole `HTTPDataRequesting`
/// l'est, et la cible de tests peut avoir l'isolation main actor par défaut.
nonisolated final class BYOKTestRequester: HTTPDataRequesting, @unchecked Sendable {
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

/// Erreur levée par une recherche, ou `nil` si elle a réussi.
nonisolated func byokThrownError(_ work: () async throws -> Void) async -> (any Error)? {
    do {
        try await work()
        return nil
    } catch {
        return error
    }
}

nonisolated func byokQueryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

// MARK: - Brave

@Suite("BraveSearchProvider")
struct BraveSearchProviderTests {
    private static let secret = "BSA-secret-key-1234"

    /// Fixture réaliste, calquée sur le format documenté (`web.results[]`, `description` avec
    /// balises de surbrillance et entités HTML).
    private static let fixture = """
    {
      "type": "search",
      "query": { "original": "swift concurrency", "more_results_available": true },
      "web": {
        "type": "search",
        "results": [
          {
            "title": "Concurrency &#x2014; Swift.org",
            "url": "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/",
            "description": "Swift has built-in support for writing <strong>asynchronous</strong> and parallel code. It&#x27;s fast &amp; safe.",
            "extra_snippets": ["autre extrait"]
          },
          {
            "title": "Swift Concurrency",
            "url": "https://developer.apple.com/documentation/swift/concurrency",
            "description": "Perform asynchronous and parallel operations."
          },
          { "title": "Lien dangereux", "url": "javascript:alert(1)", "description": "ignoré" },
          { "title": "Sans lien", "description": "ignoré" }
        ]
      }
    }
    """

    private func provider(
        status: Int = 200,
        body: String = BraveSearchProviderTests.fixture,
        requester: BYOKTestRequester? = nil
    ) -> (BraveSearchProvider, BYOKTestRequester) {
        let requester = requester ?? BYOKTestRequester(status: status, body: body)
        return (BraveSearchProvider(apiKey: Self.secret, requester: requester), requester)
    }

    @Test("décode les résultats, retire les balises et décode les entités")
    func decodesFixture() async throws {
        let (provider, _) = provider()
        let response = try await provider.search(query: "swift concurrency", options: WebSearchOptions())

        #expect(response.results.count == 2)
        #expect(response.results[0].title == "Concurrency \u{2014} Swift.org")
        #expect(response.results[0].content == "Swift has built-in support for writing asynchronous and parallel code. It's fast & safe.")
        #expect(response.results[1].url == "https://developer.apple.com/documentation/swift/concurrency")
        #expect(response.suggestions.isEmpty)
        #expect(provider.kind == .braveSearch)
    }

    @Test("sans section web : réponse vide valide, pas une erreur")
    func missingWebSectionIsEmpty() async throws {
        let (provider, _) = provider(body: #"{ "type": "search", "query": { "original": "zzz" } }"#)
        let response = try await provider.search(query: "zzz", options: WebSearchOptions())
        #expect(response.results.isEmpty)
    }

    @Test("le nombre de résultats est plafonné par maxResults")
    func capsResults() async throws {
        let (provider, _) = provider()
        let response = try await provider.search(query: "swift", options: WebSearchOptions(maxResults: 1))
        #expect(response.results.count == 1)
    }

    @Test("la requête porte l'URL, les paramètres et l'en-tête officiels, et pas la clé dans l'URL")
    func buildsRequest() throws {
        let (provider, _) = provider()
        let request = try provider.buildRequest(
            query: "  actualités swift  ",
            options: WebSearchOptions(language: "fr-FR", maxResults: 8)
        )

        #expect(request.url?.host == "api.search.brave.com")
        #expect(request.url?.path == "/res/v1/web/search")
        #expect(request.httpMethod == "GET")
        #expect(byokQueryValue("q", in: request) == "actualités swift")
        #expect(byokQueryValue("count", in: request) == "8")
        #expect(byokQueryValue("search_lang", in: request) == "fr")
        #expect(byokQueryValue("text_decorations", in: request) == "false")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == Self.secret)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.url?.absoluteString.contains(Self.secret) == false)
    }

    @Test("le « + » littéral part en %2B")
    func encodesPlus() throws {
        let (provider, _) = provider()
        let request = try provider.buildRequest(query: "tutoriel C++", options: WebSearchOptions())
        #expect(request.url?.query?.contains("C%2B%2B") == true)
        #expect(byokQueryValue("q", in: request) == "tutoriel C++")
    }

    @Test("count est borné à 1...20", arguments: [(0, "1"), (-5, "1"), (7, "7"), (20, "20"), (500, "20")])
    func clampsCount(requested: Int, expected: String) throws {
        let (provider, _) = provider()
        let request = try provider.buildRequest(query: "x", options: WebSearchOptions(maxResults: requested))
        #expect(byokQueryValue("count", in: request) == expected)
    }

    @Test("search_lang : uniquement une valeur documentée, sinon omis", arguments: [
        ("fr-FR", "fr"), ("fr", "fr"), ("en-GB", "en-gb"), ("en-US", "en"), ("pt-BR", "pt-br"),
        ("pt", "pt-pt"), ("zh-Hans", "zh-hans"), ("no", "nb"), ("de_DE", "de"),
    ] as [(String, String?)])
    func mapsSupportedLanguages(input: String, expected: String?) {
        #expect(BraveSearchProvider.searchLanguage(for: input) == expected)
    }

    @Test("langue inconnue ou absente : pas de search_lang")
    func unsupportedLanguageIsOmitted() throws {
        #expect(BraveSearchProvider.searchLanguage(for: "xx") == nil)
        #expect(BraveSearchProvider.searchLanguage(for: nil) == nil)
        #expect(BraveSearchProvider.searchLanguage(for: "") == nil)

        let (provider, _) = provider()
        let request = try provider.buildRequest(query: "x", options: WebSearchOptions(language: "xx"))
        #expect(byokQueryValue("search_lang", in: request) == nil)
    }

    @Test("statut HTTP -> WebSearchError", arguments: [
        (401, WebSearchError.unauthorized), (403, .unauthorized), (429, .rateLimited),
        (500, .unavailable), (503, .unavailable), (408, .timeout), (404, .invalidResponse),
    ])
    func mapsStatus(status: Int, expected: WebSearchError) async {
        let (provider, _) = provider(status: status, body: "{}")
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == expected)
    }

    @Test("422 avec un code de jeton invalide : clé refusée ; autre 422 : requête invalide")
    func maps422() async {
        let tokenBody = #"{"type":"ErrorResponse","error":{"id":"abc","status":422,"code":"SUBSCRIPTION_TOKEN_INVALID","detail":"The provided subscription token is invalid."}}"#
        let (invalidToken, _) = provider(status: 422, body: tokenBody)
        let (badParam, _) = provider(status: 422, body: #"{"error":{"code":"VALIDATION","detail":"bad param"}}"#)
        let (noBody, _) = provider(status: 422, body: "pas du json")

        let first = await byokThrownError { _ = try await invalidToken.search(query: "x", options: WebSearchOptions()) }
        let second = await byokThrownError { _ = try await badParam.search(query: "x", options: WebSearchOptions()) }
        let third = await byokThrownError { _ = try await noBody.search(query: "x", options: WebSearchOptions()) }
        #expect(first as? WebSearchError == .unauthorized)
        #expect(second as? WebSearchError == .invalidResponse)
        #expect(third as? WebSearchError == .invalidResponse)
    }

    @Test("200 mais corps illisible (page HTML, JSON tronqué) : invalidResponse")
    func unreadableBody() async {
        for body in ["<html>challenge</html>", #"{"web": {"results": [ {"#, "[]"] {
            let (provider, _) = provider(body: body)
            let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
            #expect(error as? WebSearchError == .invalidResponse)
        }
    }

    @Test("clé vide : missingKey, aucune requête envoyée")
    func missingKey() async {
        let requester = BYOKTestRequester(body: Self.fixture)
        let provider = BraveSearchProvider(apiKey: "   ", requester: requester)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == .missingKey)
        #expect(requester.requests.isEmpty)
    }

    @Test("requête vide : réponse vide, aucune requête envoyée (pas de quota gâché)")
    func emptyQuery() async throws {
        let (provider, requester) = provider()
        let response = try await provider.search(query: "  \n ", options: WebSearchOptions())
        #expect(response.results.isEmpty)
        #expect(requester.requests.isEmpty)
    }

    @Test("erreurs de transport : timeout, réseau, annulation")
    func transportErrors() async {
        let timeout = BraveSearchProvider(apiKey: Self.secret, requester: BYOKTestRequester { _ in throw URLError(.timedOut) })
        let offline = BraveSearchProvider(apiKey: Self.secret, requester: BYOKTestRequester { _ in throw URLError(.notConnectedToInternet) })
        let cancelled = BraveSearchProvider(apiKey: Self.secret, requester: BYOKTestRequester { _ in throw URLError(.cancelled) })

        let timeoutError = await byokThrownError { _ = try await timeout.search(query: "x", options: WebSearchOptions()) }
        let offlineError = await byokThrownError { _ = try await offline.search(query: "x", options: WebSearchOptions()) }
        let cancelledError = await byokThrownError { _ = try await cancelled.search(query: "x", options: WebSearchOptions()) }
        #expect(timeoutError as? WebSearchError == .timeout)
        #expect(offlineError as? WebSearchError == .noConnection)
        // Une annulation ne doit PAS devenir `.unavailable` : l'orchestrateur passerait à la source suivante.
        #expect(cancelledError is CancellationError)
    }

    @Test("la clé n'apparaît dans aucune erreur, même si URLError embarque l'URL")
    func keyNeverLeaks() async {
        let leaky = URL(string: "https://api.search.brave.com/res/v1/web/search?q=x&token=\(Self.secret)")
        let requester = BYOKTestRequester { _ in
            throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: leaky as Any])
        }
        let provider = BraveSearchProvider(apiKey: Self.secret, requester: requester)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }

        #expect(error as? WebSearchError == .unavailable)
        #expect(String(reflecting: error as Any).contains(Self.secret) == false)
        #expect(String(describing: error as Any).contains(Self.secret) == false)
        #expect((error as? WebSearchError)?.userFacingMessage.contains(Self.secret) == false)
        #expect(String(reflecting: provider).contains(Self.secret) == false)
    }

    @Test("validateKey : 200 valide, 429 valide mais quota atteint, 401 refusée")
    func validation() async throws {
        let ok = BraveSearchProvider(apiKey: Self.secret, requester: BYOKTestRequester(body: Self.fixture))
        let limited = BraveSearchProvider(apiKey: Self.secret, requester: BYOKTestRequester(status: 429, body: "{}"))
        let refused = BraveSearchProvider(apiKey: Self.secret, requester: BYOKTestRequester(status: 401, body: "{}"))

        #expect(try await ok.validateKey() == .valid)
        #expect(try await limited.validateKey() == .validQuotaReached)
        let error = await byokThrownError { _ = try await refused.validateKey() }
        #expect(error as? WebSearchError == .unauthorized)
    }

    @Test("validateKey envoie une seule requête minimale (count = 1)")
    func validationIsMinimal() async throws {
        let (provider, requester) = provider()
        _ = try await provider.validateKey()
        #expect(requester.requests.count == 1)
        #expect(byokQueryValue("count", in: requester.requests[0]) == "1")
    }
}

// MARK: - Tavily

@Suite("TavilySearchProvider")
struct TavilySearchProviderTests {
    private static let secret = "tvly-secret-key-5678"

    private static let fixture = """
    {
      "query": "swift concurrency",
      "follow_up_questions": null,
      "answer": null,
      "images": [],
      "results": [
        {
          "url": "https://www.swift.org/documentation/concurrency/",
          "title": "Swift Concurrency Documentation",
          "content": "Swift's concurrency model is built on   structured\\nconcurrency, actors and Sendable.",
          "score": 0.8123,
          "raw_content": null
        },
        {
          "url": "https://developer.apple.com/news/",
          "title": "",
          "content": "",
          "score": 0.4
        },
        { "url": "ftp://exemple.fr/fichier", "title": "ignoré", "content": "ignoré", "score": 0.1 }
      ],
      "response_time": 1.67,
      "request_id": "123e4567-e89b-12d3-a456-426614174111"
    }
    """

    private func provider(
        status: Int = 200,
        body: String = TavilySearchProviderTests.fixture,
        depth: TavilySearchProvider.Depth = .basic
    ) -> (TavilySearchProvider, BYOKTestRequester) {
        let requester = BYOKTestRequester(status: status, body: body)
        return (TavilySearchProvider(apiKey: Self.secret, depth: depth, requester: requester), requester)
    }

    private func jsonBody(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("décode title / url / content, nettoie les blancs, ignore les liens non http(s)")
    func decodesFixture() async throws {
        let (provider, _) = provider()
        let response = try await provider.search(query: "swift concurrency", options: WebSearchOptions())

        #expect(response.results.count == 2)
        #expect(response.results[0].title == "Swift Concurrency Documentation")
        #expect(response.results[0].content == "Swift's concurrency model is built on structured concurrency, actors and Sendable.")
        // Titre vide -> nom d'hôte ; contenu vide -> nil.
        #expect(response.results[1].title == "developer.apple.com")
        #expect(response.results[1].content == nil)
        #expect(provider.kind == .tavily)
    }

    @Test("sans tableau results : réponse vide valide")
    func missingResults() async throws {
        let (provider, _) = provider(body: #"{ "query": "zzz", "response_time": 0.5 }"#)
        let response = try await provider.search(query: "zzz", options: WebSearchOptions())
        #expect(response.results.isEmpty)
    }

    @Test("requête : POST, Bearer, JSON, profondeur basic par défaut, aucune clé dans l'URL")
    func buildsRequest() throws {
        let (provider, _) = provider()
        let request = try provider.buildRequest(
            query: "  swift  ",
            options: WebSearchOptions(language: "fr-FR", maxResults: 6)
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.tavily.com/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.secret)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try jsonBody(of: request)
        #expect(body["query"] as? String == "swift")
        #expect(body["search_depth"] as? String == "basic")
        #expect(body["topic"] as? String == "general")
        #expect(body["max_results"] as? Int == 6)
        #expect(body["include_answer"] as? Bool == false)
        #expect(body["language"] as? String == "fr")
    }

    @Test("sans langue : le champ language est absent du corps")
    func omitsLanguage() throws {
        let (provider, _) = provider()
        let body = try jsonBody(of: provider.buildRequest(query: "x", options: WebSearchOptions()))
        #expect(body["language"] == nil)
    }

    @Test("la profondeur advanced n'est utilisée que si on la demande")
    func advancedDepth() throws {
        let (provider, _) = provider(depth: .advanced)
        let body = try jsonBody(of: provider.buildRequest(query: "x", options: WebSearchOptions()))
        #expect(body["search_depth"] as? String == "advanced")
    }

    @Test("max_results est borné à 1...20", arguments: [(0, 1), (-3, 1), (12, 12), (20, 20), (99, 20)])
    func clampsMaxResults(requested: Int, expected: Int) throws {
        let (provider, _) = provider()
        let body = try jsonBody(of: provider.buildRequest(query: "x", options: WebSearchOptions(maxResults: requested)))
        #expect(body["max_results"] as? Int == expected)
    }

    @Test("les catégories académique et discussion restent des recherches générales")
    func categoriesStayGeneral() async throws {
        for category in WebSearchCategory.allCases {
            let (provider, _) = provider()
            let response = try await provider.search(query: "x", options: WebSearchOptions(category: category))
            #expect(!response.results.isEmpty)
        }
    }

    @Test("statut HTTP -> WebSearchError (432 et 433 = quota)", arguments: [
        (401, WebSearchError.unauthorized), (429, .rateLimited), (432, .rateLimited), (433, .rateLimited),
        (500, .unavailable), (502, .unavailable), (400, .invalidResponse), (422, .invalidResponse),
    ])
    func mapsStatus(status: Int, expected: WebSearchError) async {
        let (provider, _) = provider(status: status, body: #"{"detail":{"error":"x"}}"#)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == expected)
    }

    @Test("clé vide : missingKey, aucune requête ; requête vide : aucune requête")
    func guards() async throws {
        let requester = BYOKTestRequester(body: Self.fixture)
        let noKey = TavilySearchProvider(apiKey: "", requester: requester)
        let error = await byokThrownError { _ = try await noKey.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == .missingKey)

        let withKey = TavilySearchProvider(apiKey: Self.secret, requester: requester)
        let response = try await withKey.search(query: " ", options: WebSearchOptions())
        #expect(response.results.isEmpty)
        #expect(requester.requests.isEmpty)
    }

    @Test("la clé n'apparaît dans aucune erreur ni description")
    func keyNeverLeaks() async {
        let leaky = URL(string: "https://api.tavily.com/search?api_key=\(Self.secret)")
        let requester = BYOKTestRequester { _ in
            throw URLError(.secureConnectionFailed, userInfo: [NSURLErrorFailingURLErrorKey: leaky as Any])
        }
        let provider = TavilySearchProvider(apiKey: Self.secret, requester: requester)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }

        #expect(error as? WebSearchError == .unavailable)
        #expect(String(reflecting: error as Any).contains(Self.secret) == false)
        #expect(String(reflecting: provider).contains(Self.secret) == false)
    }

    @Test("annulation propagée telle quelle")
    func cancellation() async {
        let provider = TavilySearchProvider(apiKey: Self.secret, requester: BYOKTestRequester { _ in throw CancellationError() })
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error is CancellationError)
    }

    @Test("validateKey : valide, quota atteint (432), refusée")
    func validation() async throws {
        let ok = TavilySearchProvider(apiKey: Self.secret, requester: BYOKTestRequester(body: Self.fixture))
        let limited = TavilySearchProvider(apiKey: Self.secret, requester: BYOKTestRequester(status: 432, body: "{}"))
        let refused = TavilySearchProvider(apiKey: Self.secret, requester: BYOKTestRequester(status: 401, body: "{}"))

        #expect(try await ok.validateKey() == .valid)
        #expect(try await limited.validateKey() == .validQuotaReached)
        let error = await byokThrownError { _ = try await refused.validateKey() }
        #expect(error as? WebSearchError == .unauthorized)
    }
}
