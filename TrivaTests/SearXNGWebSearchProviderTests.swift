//
//  SearXNGWebSearchProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 28/10/2026.
//

import Testing
import Foundation
@testable import Triva

/// Client dont l'appel reste en vol jusqu'à `resolve(with:)` : pour annuler la `Task` pendant
/// qu'une instance est interrogée.
private actor SuspendedSearXNGClient: SearXNGSearching {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<SearXNGSearchResponse, any Error>?

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@Suite("SearXNGWebSearchProvider")
struct SearXNGWebSearchProviderTests {
    private let one = URL(string: "https://un.example.org")!
    private let two = URL(string: "https://deux.example.org")!

    private func provider(
        client: any SearXNGSearching,
        instances: [URL]? = nil
    ) -> SearXNGWebSearchProvider {
        SearXNGWebSearchProvider(failover: FailoverManager(client: client, instances: instances ?? [one, two]))
    }

    // MARK: Traduction des options

    @Test("La source se déclare .searxng")
    func kind() {
        #expect(provider(client: ScriptedInstanceClient()).kind == .searxng)
    }

    @Test("Catégorie générale : ni moteur ni catégorie forcés")
    func generalCategory() {
        let options = SearXNGWebSearchProvider.searxngOptions(for: WebSearchOptions(category: .general))

        #expect(options.engines.isEmpty)
        #expect(options.categories.isEmpty)
    }

    @Test("Catégorie académique : moteurs arxiv, google scholar, pubmed (parité avec le web)")
    func academicCategory() {
        let options = SearXNGWebSearchProvider.searxngOptions(for: WebSearchOptions(category: .academic))

        #expect(options.engines == ["arxiv", "google scholar", "pubmed"])
    }

    @Test("Catégorie discussion : moteur reddit")
    func discussionCategory() {
        let options = SearXNGWebSearchProvider.searxngOptions(for: WebSearchOptions(category: .discussion))

        #expect(options.engines == ["reddit"])
    }

    @Test("La langue est nettoyée ; une langue vide ou blanche devient nil")
    func languageIsNormalized() {
        #expect(SearXNGWebSearchProvider.searxngOptions(for: WebSearchOptions(language: " FR ")).language == "fr")
        #expect(SearXNGWebSearchProvider.searxngOptions(for: WebSearchOptions(language: "  ")).language == nil)
        #expect(SearXNGWebSearchProvider.searxngOptions(for: WebSearchOptions(language: nil)).language == nil)
    }

    @Test("Les options traduites arrivent jusqu'au client SearXNG")
    func optionsReachTheClient() async throws {
        let client = ScriptedInstanceClient()

        _ = try await provider(client: client).search(
            query: "  théorie des cordes  ",
            options: WebSearchOptions(language: "fr", category: .academic)
        )

        #expect(await client.lastQuery == "théorie des cordes")
        #expect(await client.lastOptions?.engines == ["arxiv", "google scholar", "pubmed"])
        #expect(await client.lastOptions?.language == "fr")
    }

    // MARK: Résultats

    @Test("maxResults tronque les résultats et garde les suggestions")
    func truncatesToMaxResults() async throws {
        let client = ScriptedInstanceClient(response: ScriptedInstanceClient.sampleResponse(count: 8))

        let response = try await provider(client: client).search(query: "x", options: WebSearchOptions(maxResults: 3))

        #expect(response.results.count == 3)
        #expect(response.results.map(\.title) == ["Résultat 0", "Résultat 1", "Résultat 2"])
        #expect(response.suggestions == ["suggestion"])
    }

    @Test("Sous le plafond, la réponse est rendue telle quelle")
    func belowTheCapIsUntouched() async throws {
        let client = ScriptedInstanceClient(response: ScriptedInstanceClient.sampleResponse(count: 2))

        let response = try await provider(client: client).search(query: "x", options: WebSearchOptions(maxResults: 10))

        #expect(response.results.count == 2)
    }

    @Test("Un plafond nul ou négatif garde au moins un résultat")
    func capIsAtLeastOne() async throws {
        let client = ScriptedInstanceClient(response: ScriptedInstanceClient.sampleResponse(count: 4))

        let response = try await provider(client: client).search(query: "x", options: WebSearchOptions(maxResults: 0))

        #expect(response.results.count == 1)
    }

    @Test("Requête vide : réponse vide, aucun appel réseau")
    func blankQueryDoesNotHitTheNetwork() async throws {
        let client = ScriptedInstanceClient()

        let response = try await provider(client: client).search(query: "   \n", options: WebSearchOptions())

        #expect(response.results.isEmpty)
        #expect(await client.calledInstances.isEmpty)
    }

    // MARK: Erreurs

    @Test("Toutes les instances ont expiré : .timeout")
    func allTimeouts() async {
        let client = ScriptedInstanceClient(failures: [one: SearXNGClientError.timeout, two: SearXNGClientError.timeout])

        await #expect(throws: WebSearchError.timeout) {
            try await provider(client: client).search(query: "x", options: WebSearchOptions())
        }
    }

    @Test("Toutes les instances limitent le débit (429) : .rateLimited")
    func allRateLimited() async {
        let limited = SearXNGClientError.requestFailed(statusCode: 429)
        let client = ScriptedInstanceClient(failures: [one: limited, two: limited])

        await #expect(throws: WebSearchError.rateLimited) {
            try await provider(client: client).search(query: "x", options: WebSearchOptions())
        }
    }

    @Test("Échecs de natures différentes : .unavailable")
    func mixedFailures() async {
        let client = ScriptedInstanceClient(failures: [
            one: SearXNGClientError.timeout,
            two: SearXNGClientError.requestFailed(statusCode: 403)
        ])

        await #expect(throws: WebSearchError.unavailable) {
            try await provider(client: client).search(query: "x", options: WebSearchOptions())
        }
    }

    @Test("Aucune instance ne sert du JSON (page anti-robot) : .unavailable, pas .invalidResponse")
    func antiBotPagesAreUnavailable() async {
        let client = ScriptedInstanceClient(failures: [
            one: SearXNGClientError.decodingFailed,
            two: SearXNGClientError.decodingFailed
        ])

        await #expect(throws: WebSearchError.unavailable) {
            try await provider(client: client).search(query: "x", options: WebSearchOptions())
        }
    }

    @Test("Aucune instance configurée : .unavailable")
    func noInstances() async {
        let client = ScriptedInstanceClient()

        await #expect(throws: WebSearchError.unavailable) {
            try await provider(client: client, instances: []).search(query: "x", options: WebSearchOptions())
        }
    }

    @Test("Une instance a vu l'appareil hors ligne : .noConnection, même mêlée à d'autres motifs")
    func deviceOfflineWinsOverOtherReasons() {
        let mapped = SearXNGWebSearchProvider.webSearchError(for: FailoverExhaustedError(reasons: [.accessDenied, .network], deviceOffline: true))
        #expect(mapped == .noConnection)
        #expect(SearXNGWebSearchProvider.webSearchError(for: FailoverExhaustedError(reasons: [.network, .network])) == .unavailable)
    }

    @Test("La traduction d'erreur ne laisse rien du serveur : un message fixe, identique à chaque fois")
    func errorMessagesAreFixed() {
        let mapped = SearXNGWebSearchProvider.webSearchError(for: FailoverExhaustedError(reasons: [.timeout, .notJSON]))

        #expect(mapped == .unavailable)
        #expect(mapped.userFacingMessage == WebSearchError.unavailable.userFacingMessage)
        #expect(SearXNGWebSearchProvider.webSearchError(for: FailoverExhaustedError(reasons: [])) == .unavailable)
        #expect(SearXNGWebSearchProvider.webSearchError(for: URLError(.badServerResponse)) == .unavailable)
    }

    @Test("Un succès sur une deuxième instance masque l'échec de la première")
    func failoverIsTransparent() async throws {
        let client = ScriptedInstanceClient(failures: [one: SearXNGClientError.decodingFailed])

        let response = try await provider(client: client).search(query: "x", options: WebSearchOptions())

        #expect(response.results.count == 1)
        #expect(await client.calledInstances == [one, two])
    }

    // MARK: Annulation

    @Test("Annulation pendant la recherche : CancellationError, jamais une WebSearchError")
    func cancellationIsPropagated() async throws {
        let client = SuspendedSearXNGClient()
        let source = provider(client: client)

        let task = Task { try await source.search(query: "x", options: WebSearchOptions()) }
        while await client.callCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        await client.resolve(with: URLError(.cancelled))

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // Une annulation n'est pas une panne d'instance : rien n'a été essayé ensuite.
        #expect(await client.callCount == 1)
    }
}
