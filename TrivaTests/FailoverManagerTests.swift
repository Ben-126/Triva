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

// MARK: - Annulation (findings FailoverManager.swift:43/48 de la revue 0.8)

/// Client SearXNG factice qui répond normalement par défaut, mais dont le
/// PROCHAIN appel à `search` reste en vol après `hangNextCall()` jusqu'à ce
/// que le test appelle `resolve(with:)` — nécessaire pour annuler la `Task`
/// englobante PENDANT que `search(query:)` est réellement en vol sur une
/// instance précise, sans bloquer les appels qui doivent réussir normalement
/// (recherche initiale qui peuple le cache, recherche finale qui vérifie
/// qu'il n'a pas été perdu).
private actor ControllableSearXNGClient: SearXNGSearching {
    private(set) var calledInstances: [URL] = []
    private var continuation: CheckedContinuation<SearXNGSearchResponse, Error>?
    private var shouldHangNextCall = false
    private let response: SearXNGSearchResponse

    init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: [])) {
        self.response = response
    }

    func hangNextCall() {
        shouldHangNextCall = true
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calledInstances.append(instance)
        guard shouldHangNextCall else { return response }
        shouldHangNextCall = false
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@Suite("FailoverManager — annulation")
struct FailoverManagerCancellationTests {
    private let instance1 = URL(string: "https://instance1.example")!
    private let instance2 = URL(string: "https://instance2.example")!

    private func waitUntil(
        maxAttempts: Int = 200,
        _ condition: () async -> Bool
    ) async {
        var attempts = 0
        while attempts < maxAttempts {
            if await condition() { return }
            await Task.yield()
            attempts += 1
        }
        Issue.record("Timeout")
    }

    @Test("Une Task annulée PENDANT client.search(...) rethrow immédiatement au lieu de continuer sur les instances restantes — ne gaspille pas de recherches dont plus personne n'a besoin")
    func cancellationStopsIterationInsteadOfTryingRemainingInstances() async {
        let client = ControllableSearXNGClient()
        let manager = FailoverManager(client: client, instances: [instance1, instance2])
        await client.hangNextCall()

        let task = Task { try await manager.search(query: "test") }
        await waitUntil { await client.calledInstances.count == 1 }

        task.cancel()
        await client.resolve(with: CancellationError())

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }

        // instance2 n'a JAMAIS été appelée : la boucle s'est arrêtée dès la
        // détection de l'annulation, pas après avoir épuisé toute la liste.
        let called = await client.calledInstances
        #expect(called == [instance1])
    }

    @Test("Une annulation en cours de recherche ne réinitialise PAS cachedInstance — la prochaine recherche réelle (non annulée) réutilise directement la dernière instance qui fonctionnait")
    func cancellationDoesNotClearCachedInstance() async throws {
        let client = ControllableSearXNGClient()
        let manager = FailoverManager(client: client, instances: [instance1, instance2])

        // 1re recherche, réussie : met instance1 en cache.
        _ = try await manager.search(query: "premiere recherche")

        // 2e recherche, annulée pendant qu'elle est en vol sur instance1
        // (celle en cache, essayée en premier).
        await client.hangNextCall()
        let task = Task { try await manager.search(query: "deuxieme recherche, annulee") }
        await waitUntil { await client.calledInstances.count == 2 }
        task.cancel()
        await client.resolve(with: CancellationError())
        _ = await task.result

        // 3e recherche, réelle (non annulée) : doit directement réessayer
        // instance1 (toujours en cache), PAS repartir de zéro sur toute la
        // liste — l'annulation précédente n'a pas dû effacer le cache.
        _ = try await manager.search(query: "troisieme recherche, reelle")

        let called = await client.calledInstances
        #expect(called == [instance1, instance1, instance1])
    }
}
