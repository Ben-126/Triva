//
//  SearXNGClientTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// `URLProtocol` factice : intercepte les requêtes de l'`URLSession` de test
/// pour simuler des réponses HTTP (statut, corps) ou des erreurs de transport
/// (timeout) sans le moindre appel réseau réel.
private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var errorToThrow: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.errorToThrow {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// `MockURLProtocol.requestHandler` / `.errorToThrow` sont des statics partagés.
// Sans `.serialized`, Swift Testing exécute les tests de cette suite en
// parallèle et l'`init()`/l'assignation d'un test peut écraser ces statics
// avant que la closure d'un autre test n'ait tourné — d'où des tests qui
// n'obtiennent jamais d'erreur, ou des `LockedBox` restés à `nil`.
@MainActor
@Suite("SearXNGClient", .serialized)
struct SearXNGClientTests {
    private let instance = URL(string: "https://searx.example")!

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    init() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.errorToThrow = nil
    }

    // MARK: - buildURL (via search, en inspectant la requête interceptée)

    @Test("Construit l'URL avec la query et le format json")
    func buildsURLWithQueryAndFormat() async throws {
        let capturedURL = LockedBox<URL?>(nil)
        MockURLProtocol.requestHandler = { request in
            capturedURL.value = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONEncoder().encode(SearXNGSearchResponse(results: [], suggestions: []))
            return (response, body)
        }
        let client = SearXNGClient(urlSession: Self.makeSession())

        _ = try await client.search(query: "chat noir", options: SearXNGSearchOptions(), instance: instance)

        let url = try #require(capturedURL.value)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/search")
        let items = try #require(components.queryItems)
        #expect(items.contains(URLQueryItem(name: "format", value: "json")))
        #expect(items.contains(URLQueryItem(name: "q", value: "chat noir")))
    }

    @Test("Ajoute les paramètres optionnels quand ils sont renseignés")
    func addsOptionalParametersWhenProvided() async throws {
        let capturedURL = LockedBox<URL?>(nil)
        MockURLProtocol.requestHandler = { request in
            capturedURL.value = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONEncoder().encode(SearXNGSearchResponse(results: [], suggestions: []))
            return (response, body)
        }
        let client = SearXNGClient(urlSession: Self.makeSession())
        let options = SearXNGSearchOptions(
            categories: ["general", "images"],
            engines: ["duckduckgo", "bing"],
            language: "fr",
            pageNumber: 2,
            timeRange: "month"
        )

        _ = try await client.search(query: "test", options: options, instance: instance)

        let url = try #require(capturedURL.value)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "categories", value: "general,images")))
        #expect(items.contains(URLQueryItem(name: "engines", value: "duckduckgo,bing")))
        #expect(items.contains(URLQueryItem(name: "language", value: "fr")))
        #expect(items.contains(URLQueryItem(name: "pageno", value: "2")))
        #expect(items.contains(URLQueryItem(name: "time_range", value: "month")))
    }

    @Test("Envoie le header Accept application/json")
    func sendsAcceptHeader() async throws {
        let capturedHeader = LockedBox<String?>(nil)
        MockURLProtocol.requestHandler = { request in
            capturedHeader.value = request.value(forHTTPHeaderField: "Accept")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONEncoder().encode(SearXNGSearchResponse(results: [], suggestions: []))
            return (response, body)
        }
        let client = SearXNGClient(urlSession: Self.makeSession())

        _ = try await client.search(query: "test", options: SearXNGSearchOptions(), instance: instance)

        #expect(capturedHeader.value == "application/json")
    }

    // MARK: - buildURL : encodage du « + » (bug 12 de la revue V1)

    /// Le test d'aller-retour `buildsURLWithQueryAndFormat` ne pouvait PAS voir
    /// ce bug : `URLComponents.queryItems` relit la query selon la RFC 3986 et
    /// rend un `+` brut comme un `+`. Il faut inspecter la chaîne ENCODÉE, celle
    /// qui part réellement sur le réseau.
    @Test("Encode le « + » de la requête en %2B plutôt qu'en « + » brut")
    func encodesPlusSignAsPercent2B() async throws {
        let url = try await capturedRequestURL(forQuery: "tutoriel C++")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encodedQuery = try #require(components.percentEncodedQuery)
        #expect(encodedQuery.contains("q=tutoriel%20C%2B%2B"))
        #expect(!encodedQuery.contains("+"))
        // Aller-retour RFC 3986 : `%2B` redevient bien `+`, donc aucun double
        // encodage (`%252B`) n'a été introduit par le correctif.
        #expect(components.queryItems?.contains(URLQueryItem(name: "q", value: "tutoriel C++")) == true)
    }

    /// Test SÉMANTIQUE : on relit la query exactement comme SearXNG la relit
    /// (voir `formDecodedValue`). Avant le correctif, « tutoriel C++ » était lu
    /// « tutoriel C » suivi de deux espaces, « 2+2 » devenait « 2 2 ». Le
    /// dernier cas mêle `+`, `&`, `=`, `%` et espaces pour vérifier que le
    /// réencodage du `+` ne casse pas l'encodage des autres caractères.
    @Test(
        "SearXNG relit exactement la requête tapée, « + » compris",
        arguments: ["tutoriel C++", "Canal+", "Disney+", "2+2", "C++ & Rust = 100%"]
    )
    func serverFormDecodingReadsBackTheExactQuery(query: String) async throws {
        let url = try await capturedRequestURL(forQuery: query)

        let encodedQuery = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(Self.formDecodedValue(named: "q", in: encodedQuery) == query)
    }

    /// Garde-fou contre un correctif trop large (décoder puis réencoder toute
    /// la query, ou percent-encoder la valeur avant de la confier à
    /// `URLComponents`) : un « %2B » tapé tel quel par l'utilisateur doit
    /// arriver au serveur comme les trois caractères « %2B », pas comme « + ».
    @Test("Un « %2B » tapé littéralement arrive intact au serveur")
    func literalPercent2BInQueryIsNotDecodedAsPlus() async throws {
        let url = try await capturedRequestURL(forQuery: "encodage %2B")

        let encodedQuery = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(encodedQuery.contains("q=encodage%20%252B"))
        #expect(Self.formDecodedValue(named: "q", in: encodedQuery) == "encodage %2B")
    }

    // MARK: - search : cas de succès

    @Test("Décode une réponse JSON valide avec statut 200")
    func decodesValidJSONResponseWithStatus200() async throws {
        let expected = SearXNGSearchResponse(
            results: [
                SearXNGSearchResult(
                    title: "Titre",
                    url: "https://example.com",
                    content: "Contenu",
                    imgSrc: nil,
                    thumbnailSrc: nil,
                    thumbnail: nil,
                    author: nil,
                    iframeSrc: nil
                ),
            ],
            suggestions: ["autre requête"]
        )
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try JSONEncoder().encode(expected))
        }
        let client = SearXNGClient(urlSession: Self.makeSession())

        let result = try await client.search(query: "test", options: SearXNGSearchOptions(), instance: instance)

        #expect(result == expected)
    }

    // MARK: - search : cas d'erreur

    @Test("Timeout de transport devient SearXNGClientError.timeout")
    func transportTimeoutBecomesTimeoutError() async throws {
        MockURLProtocol.errorToThrow = URLError(.timedOut)
        let client = SearXNGClient(urlSession: Self.makeSession())

        await #expect(throws: SearXNGClientError.timeout) {
            _ = try await client.search(query: "test", options: SearXNGSearchOptions(), instance: instance)
        }
    }

    @Test("Une erreur de transport non-timeout devient SearXNGClientError.transportError")
    func nonTimeoutTransportErrorBecomesTransportError() async throws {
        MockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        let client = SearXNGClient(urlSession: Self.makeSession())

        await #expect(throws: SearXNGClientError.transportError) {
            _ = try await client.search(query: "test", options: SearXNGSearchOptions(), instance: instance)
        }
    }

    @Test(
        "Un statut HTTP d'erreur devient SearXNGClientError.requestFailed avec le bon code",
        arguments: [429, 500, 503]
    )
    func nonSuccessStatusBecomesRequestFailed(statusCode: Int) async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = SearXNGClient(urlSession: Self.makeSession())

        await #expect(throws: SearXNGClientError.requestFailed(statusCode: statusCode)) {
            _ = try await client.search(query: "test", options: SearXNGSearchOptions(), instance: instance)
        }
    }

    @Test("Un statut 200 avec une réponse HTML invalide devient SearXNGClientError.decodingFailed")
    func htmlBodyWithStatus200BecomesDecodingFailed() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let html = Data("<html><body>Vérification anti-bot</body></html>".utf8)
            return (response, html)
        }
        let client = SearXNGClient(urlSession: Self.makeSession())

        await #expect(throws: SearXNGClientError.decodingFailed) {
            _ = try await client.search(query: "test", options: SearXNGSearchOptions(), instance: instance)
        }
    }

    // MARK: - Outils

    /// Lance une recherche sur `query` et renvoie l'URL de la requête telle
    /// qu'interceptée par `MockURLProtocol`, c'est-à-dire telle qu'`URLSession`
    /// l'enverrait : on vérifie ainsi que l'encodage survit au passage par
    /// `URLRequest`, pas seulement la sortie de `buildURL` (qui reste privé).
    private func capturedRequestURL(forQuery query: String) async throws -> URL {
        let capturedURL = LockedBox<URL?>(nil)
        MockURLProtocol.requestHandler = { request in
            capturedURL.value = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONEncoder().encode(SearXNGSearchResponse(results: [], suggestions: []))
            return (response, body)
        }
        let client = SearXNGClient(urlSession: Self.makeSession())

        _ = try await client.search(query: query, options: SearXNGSearchOptions(), instance: instance)

        return try #require(capturedURL.value)
    }

    /// Relit la valeur du paramètre `name` comme le fait RÉELLEMENT SearXNG :
    /// Flask/werkzeug décode la query string au format
    /// `application/x-www-form-urlencoded` (même règle que `urllib.parse.parse_qsl`
    /// de Python) — `&` sépare les paires, le premier `=` sépare nom et valeur,
    /// `+` vaut une espace, PUIS les `%XX` sont décodés. L'ordre compte : décoder
    /// d'abord transformerait un `%2B` en `+`, ensuite pris à tort pour une espace.
    /// `URLComponents.queryItems` ne convient pas ici : il suit la RFC 3986 et
    /// garde le `+` tel quel, ce qui masque précisément le bug 12.
    private static func formDecodedValue(named name: String, in percentEncodedQuery: String) -> String? {
        let formDecode: (Substring) -> String? = { raw in
            raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        for pair in percentEncodedQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first, formDecode(rawName) == name else { continue }
            return parts.count > 1 ? formDecode(parts[1]) : ""
        }
        return nil
    }
}

/// Petite boîte pour capturer une valeur depuis la closure `requestHandler`
/// (exécutée hors de l'isolation de la méthode de test) sans introduire de
/// dépendance externe. `NSLock` est suffisant : un seul accès concurrent
/// possible par test.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { self._value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
