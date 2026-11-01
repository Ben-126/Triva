//
//  SearXNGProbeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/10/2026.
//

import Testing
import Foundation
@testable import Triva

/// `URLProtocol` factice : la sonde traverse ici le VRAI `SearXNGClient` (décodage JSON compris),
/// pour vérifier la distinction « vraie réponse JSON » / « page HTML anti-robot » de bout en
/// bout, sans réseau.
private final class ProbeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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

// Le `handler` est un static partagé : sans `.serialized`, deux tests s'écraseraient.
@MainActor
@Suite("SearXNGInstanceHealthProbe", .serialized)
struct SearXNGInstanceHealthProbeTests {
    private let instance = URL(string: "https://searx.example")!

    private static func makeProbe() -> SearXNGInstanceHealthProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return SearXNGInstanceHealthProbe(client: SearXNGClient(urlSession: URLSession(configuration: configuration)))
    }

    private static func respond(status: Int, body: String) {
        ProbeURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    @Test("Une vraie réponse JSON avec des résultats est saine")
    func realJSONIsHealthy() async throws {
        Self.respond(status: 200, body: """
        {"results":[{"title":"A","url":"https://a.test","content":"x"},{"title":"B","url":"https://b.test"}],"suggestions":[]}
        """)

        let result = try await Self.makeProbe().probe(instance)

        #expect(result.verdict == .healthy(resultCount: 2))
        #expect(result.isHealthy)
    }

    @Test("Une page HTML renvoyée avec un statut 200 (défi anti-robot) est rangée en notJSON")
    func antiBotHTMLIsNotJSON() async throws {
        Self.respond(status: 200, body: "<html><head><title>Making sure you're not a bot!</title></head></html>")

        let result = try await Self.makeProbe().probe(instance)

        #expect(result.verdict == .failed(.notJSON))
        #expect(!result.isHealthy)
    }

    @Test("Un 403 (format JSON désactivé par l'administrateur) est rangé en accessDenied")
    func forbiddenIsAccessDenied() async throws {
        Self.respond(status: 403, body: "Forbidden")

        let result = try await Self.makeProbe().probe(instance)

        #expect(result.verdict == .failed(.accessDenied))
    }

    @Test("Un 429 est rangé en rateLimited")
    func tooManyRequestsIsRateLimited() async throws {
        Self.respond(status: 429, body: "")

        #expect(try await Self.makeProbe().probe(instance).verdict == .failed(.rateLimited))
    }

    @Test("Du JSON valide mais vide (moteurs bloqués) n'est PAS sain")
    func emptyJSONIsNotHealthy() async throws {
        Self.respond(status: 200, body: #"{"results":[],"suggestions":[]}"#)

        let result = try await Self.makeProbe().probe(instance)

        #expect(result.verdict == .failed(.emptyResults))
    }

    @Test("Un délai dépassé est rangé en timeout")
    func timeoutIsReported() async throws {
        ProbeURLProtocol.handler = { _ in throw URLError(.timedOut) }

        #expect(try await Self.makeProbe().probe(instance).verdict == .failed(.timeout))
    }

    @Test("La sonde envoie la requête neutre « test », jamais autre chose")
    func probeSendsNeutralQuery() async throws {
        let client = ScriptedInstanceClient()

        _ = try await SearXNGInstanceHealthProbe(client: client).probe(instance)

        #expect(await client.lastQuery == "test")
        #expect(await client.lastOptions == SearXNGSearchOptions())
    }

    @Test("Une sonde annulée lève CancellationError au lieu de se déclarer « injoignable »")
    func cancelledProbeThrowsCancellation() async {
        struct SlowClient: SearXNGSearching {
            func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
                try await Task.sleep(for: .seconds(30))
                return SearXNGSearchResponse(results: [], suggestions: [])
            }
        }
        let probe = SearXNGInstanceHealthProbe(client: SlowClient())
        let instance = instance

        let task = Task { try await probe.probe(instance) }
        task.cancel()
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
    }
}

@MainActor
@Suite("InstanceProbeBatch")
struct InstanceProbeBatchTests {
    private let instances = (0..<8).map { URL(string: "https://i\($0).example")! }

    @Test("Sonde toutes les instances, en respectant la concurrence maximale")
    func probesAllWithBoundedConcurrency() async {
        let healthy = Set(instances.prefix(3))
        let prober = ScriptedProber(healthy: healthy)

        let results = await InstanceProbeBatch.run(instances, using: prober, concurrency: 3)

        #expect(results.count == 8)
        #expect(Set(results.filter { $0.value.isHealthy }.keys) == healthy)
        let maxRunning = await prober.maxRunning
        #expect(maxRunning <= 3)
        #expect(maxRunning >= 2)
    }

    @Test("Les verdicts alimentent le store de fiabilité")
    func feedsReliabilityStore() async {
        let store = InstanceReliabilityStore()
        let prober = ScriptedProber(healthy: [instances[0]])

        _ = await InstanceProbeBatch.run(Array(instances.prefix(2)), using: prober, store: store)

        #expect(store.record(for: instances[0])?.successes == 1)
        #expect(store.record(for: instances[1])?.lastFailureReason == .notJSON)
        #expect(store.tier(for: instances[0]) == .good)
    }

    @Test("Une liste vide ne fait rien")
    func emptyListDoesNothing() async {
        let results = await InstanceProbeBatch.run([], using: ScriptedProber(healthy: []))
        #expect(results.isEmpty)
    }
}
