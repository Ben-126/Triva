//
//  FeedFetcherTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Réponse HTTP écrite d'avance, ou erreur réseau.
private enum ScriptedResponse: Sendable {
    case http(Int, headers: [String: String], body: String)
    case failure
}

/// Exécuteur HTTP factice : rend les réponses dans l'ordre et garde les requêtes reçues.
private actor ScriptedRequester: HTTPDataRequesting {
    private var responses: [ScriptedResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [ScriptedResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch responses.removeFirst() {
        case .failure:
            throw URLError(.notConnectedToInternet)
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(filePath: "/"), statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers
            )
            return (Data(body.utf8), response ?? URLResponse())
        }
    }
}

/// Horloge réglable, partagée entre le test et le lecteur.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private let rss = """
<rss><channel><item><title>Un titre</title><link>https://example.test/a</link>\
<pubDate>Wed, 11 Nov 2026 10:00:00 +0000</pubDate></item></channel></rss>
"""

private let source = FeedSource(
    id: "test", name: "Test",
    url: URL(string: "https://feeds.example.test/rss.xml") ?? URL(filePath: "/"),
    termsURL: URL(string: "https://example.test/terms") ?? URL(filePath: "/")
)

@Suite("HTTPFeedFetcher")
struct HTTPFeedFetcherTests {
    private func makeFetcher(
        _ responses: [ScriptedResponse],
        clock: Clock = Clock(Date(timeIntervalSince1970: 1_794_391_200))
    ) -> (fetcher: HTTPFeedFetcher, requester: ScriptedRequester, clock: Clock) {
        let requester = ScriptedRequester(responses)
        let fetcher = HTTPFeedFetcher(
            requester: requester,
            store: FeedRevalidationStore(freshnessWindow: 300),
            now: { clock.now }
        )
        return (fetcher, requester, clock)
    }

    @Test("lit un flux et envoie une requête propre : pas de cookie, Accept et UA, aucune clé")
    func readsAFeed() async throws {
        let (fetcher, requester, _) = makeFetcher([.http(200, headers: [:], body: rss)])

        let items = try await fetcher.items(from: source)

        #expect(items.map(\.title) == ["Un titre"])
        let request = try #require(await requester.requests.first)
        #expect(request.url == source.url)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Triva/") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("rss+xml") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("un flux lu il y a moins de 5 minutes est resservi sans requête")
    func freshFeedIsNotRequestedAgain() async throws {
        let (fetcher, requester, clock) = makeFetcher([.http(200, headers: ["ETag": "\"v1\""], body: rss)])

        _ = try await fetcher.items(from: source)
        clock.advance(by: 120)
        let again = try await fetcher.items(from: source)

        #expect(again.count == 1)
        #expect(await requester.requests.count == 1)
    }

    @Test("passé 5 minutes : requête conditionnelle, et un 304 resserre les articles gardés")
    func notModifiedReusesItems() async throws {
        let (fetcher, requester, clock) = makeFetcher([
            .http(200, headers: ["ETag": "\"v1\"", "Last-Modified": "Wed, 11 Nov 2026 09:00:00 GMT"], body: rss),
            .http(304, headers: [:], body: ""),
        ])

        _ = try await fetcher.items(from: source)
        clock.advance(by: 301)
        let items = try await fetcher.items(from: source)

        #expect(items.map(\.title) == ["Un titre"])
        let second = try #require(await requester.requests.last)
        #expect(second.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(second.value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 11 Nov 2026 09:00:00 GMT")
    }

    @Test("un 304 rajeunit l'entrée : pas de nouvelle requête dans les 5 minutes qui suivent")
    func notModifiedRenewsFreshness() async throws {
        let (fetcher, requester, clock) = makeFetcher([
            .http(200, headers: ["ETag": "\"v1\""], body: rss),
            .http(304, headers: [:], body: ""),
        ])

        _ = try await fetcher.items(from: source)
        clock.advance(by: 301)
        _ = try await fetcher.items(from: source)
        clock.advance(by: 100)
        _ = try await fetcher.items(from: source)

        #expect(await requester.requests.count == 2)
    }

    @Test("un flux modifié (200) remplace les articles gardés")
    func modifiedFeedReplacesItems() async throws {
        let updated = rss.replacingOccurrences(of: "Un titre", with: "Autre titre")
        let (fetcher, _, clock) = makeFetcher([
            .http(200, headers: ["ETag": "\"v1\""], body: rss),
            .http(200, headers: ["ETag": "\"v2\""], body: updated),
        ])

        _ = try await fetcher.items(from: source)
        clock.advance(by: 301)

        #expect(try await fetcher.items(from: source).map(\.title) == ["Autre titre"])
    }

    @Test("statut d'erreur : .badStatus, rien n'est gardé", arguments: [403, 404, 429, 500])
    func badStatus(code: Int) async {
        let (fetcher, _, _) = makeFetcher([.http(code, headers: [:], body: "<html>Non</html>")])

        await #expect(throws: FeedFetchError.badStatus(code)) {
            try await fetcher.items(from: source)
        }
    }

    @Test("hors ligne : .network")
    func offline() async {
        let (fetcher, _, _) = makeFetcher([.failure])

        await #expect(throws: FeedFetchError.network) {
            try await fetcher.items(from: source)
        }
    }

    @Test("une réponse qui n'est pas un flux : .unreadable")
    func notAFeed() async {
        let (fetcher, _, _) = makeFetcher([.http(200, headers: [:], body: "<html><body>Bienvenue")])

        await #expect(throws: FeedFetchError.unreadable) {
            try await fetcher.items(from: source)
        }
    }

    @Test("une réponse démesurée est refusée avant d'être lue")
    func tooLarge() async {
        let huge = String(repeating: "x", count: HTTPFeedFetcher.maximumResponseBytes + 1)
        let (fetcher, _, _) = makeFetcher([.http(200, headers: [:], body: huge)])

        await #expect(throws: FeedFetchError.tooLarge) {
            try await fetcher.items(from: source)
        }
    }

    @Test("un échec n'efface pas ce qu'on avait : le flux suivant repart de zéro sans validateurs périmés")
    func failureAfterSuccessKeepsValidators() async throws {
        let (fetcher, requester, clock) = makeFetcher([
            .http(200, headers: ["ETag": "\"v1\""], body: rss),
            .failure,
            .http(304, headers: [:], body: ""),
        ])

        _ = try await fetcher.items(from: source)
        clock.advance(by: 301)
        await #expect(throws: FeedFetchError.network) { try await fetcher.items(from: source) }
        let items = try await fetcher.items(from: source)

        #expect(items.count == 1)
        #expect(await requester.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }
}
