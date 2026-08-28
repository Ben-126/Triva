//
//  FailoverManagerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockClientError: Error, Sendable, Equatable {
    case simulatedFailure
}

/// Client SearXNG factice : simule des instances qui échouent ou réussissent,
/// et journalise l'ordre des instances appelées pour vérifier le comportement
/// de bascule sans effectuer le moindre appel réseau réel.
private actor MockSearXNGClient: SearXNGSearching {
    private var failingInstances: Set<URL>
    private let response: SearXNGSearchResponse
    private(set) var calledInstances: [URL] = []

    init(failingInstances: Set<URL> = [], response: SearXNGSearchResponse = MockSearXNGClient.emptyResponse) {
        self.failingInstances = failingInstances
        self.response = response
    }

    static let emptyResponse = SearXNGSearchResponse(results: [], suggestions: [])

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calledInstances.append(instance)
        if failingInstances.contains(instance) {
            throw MockClientError.simulatedFailure
        }
        return response
    }
}

@Suite("FailoverManager")
struct FailoverManagerTests {
    private let instance1 = URL(string: "https://instance1.example")!
    private let instance2 = URL(string: "https://instance2.example")!
    private let instance3 = URL(string: "https://instance3.example")!

    @Test("Bascule vers l'instance suivante quand la première échoue")
    func fallsBackToNextInstanceOnFailure() async throws {
        let mockClient = MockSearXNGClient(failingInstances: [instance1])
        let manager = FailoverManager(client: mockClient, instances: [instance1, instance2, instance3])

        _ = try await manager.search(query: "test")

        let called = await mockClient.calledInstances
        #expect(called == [instance1, instance2])
    }

    @Test("Réutilise directement l'instance en cache tant qu'elle fonctionne")
    func reusesCachedInstanceWithoutRetestingOthers() async throws {
        let mockClient = MockSearXNGClient(failingInstances: [instance1])
        let manager = FailoverManager(client: mockClient, instances: [instance1, instance2, instance3])

        _ = try await manager.search(query: "premiere recherche")
        _ = try await manager.search(query: "deuxieme recherche")

        let called = await mockClient.calledInstances
        // Première recherche : instance1 échoue, instance2 réussit (mise en cache).
        // Deuxième recherche : instance2 est essayée en premier et réussit directement,
        // sans re-tester instance1 ni instance3.
        #expect(called == [instance1, instance2, instance2])
    }

    @Test("Remonte une erreur propre quand toutes les instances échouent")
    func throwsWhenAllInstancesFail() async throws {
        let mockClient = MockSearXNGClient(failingInstances: [instance1, instance2, instance3])
        let manager = FailoverManager(client: mockClient, instances: [instance1, instance2, instance3])

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await manager.search(query: "test")
        }
    }

    @Test("Remonte une erreur claire quand aucune instance n'est configurée")
    func throwsWhenNoInstancesConfigured() async throws {
        let mockClient = MockSearXNGClient()
        let manager = FailoverManager(client: mockClient, instances: [])

        await #expect(throws: FailoverError.noInstancesConfigured) {
            _ = try await manager.search(query: "test")
        }
    }

    @Test("Retente une instance en cache tombée en panne, puis bascule")
    func fallsBackAgainWhenCachedInstanceStopsWorking() async throws {
        let mockClient = MockSearXNGClient(failingInstances: [instance1])
        let manager = FailoverManager(client: mockClient, instances: [instance1, instance2, instance3])

        _ = try await manager.search(query: "premiere recherche")
        await mockClient.setFailingInstances([instance2])
        _ = try await manager.search(query: "deuxieme recherche")

        let called = await mockClient.calledInstances
        #expect(called == [instance1, instance2, instance2, instance1])
    }
}

private extension MockSearXNGClient {
    func setFailingInstances(_ instances: Set<URL>) {
        failingInstances = instances
    }
}
