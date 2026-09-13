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
            engines: ["google", "bing"],
            language: "fr",
            pageNumber: 2,
            timeRange: "month"
        )

        _ = try await client.search(query: "test", options: options, instance: instance)

        let url = try #require(capturedURL.value)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "categories", value: "general,images")))
        #expect(items.contains(URLQueryItem(name: "engines", value: "google,bing")))
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
