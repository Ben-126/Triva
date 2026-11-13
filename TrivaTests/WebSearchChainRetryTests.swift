//
//  WebSearchChainRetryTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation
import Synchronization
import Testing
@testable import Triva

/// Source qui rend, appel après appel, les issues d'un script (la dernière se répète). Sans réseau.
/// Classe + `Mutex` : voir `ScriptedInstanceClient` (piège des acteurs internes de la cible de tests).
nonisolated final class SequencedWebSearchProvider: WebSearchProviding, Sendable {
    enum Step: Sendable {
        case found
        case failure(WebSearchError)
    }

    let kind: WebSearchSourceKind
    private let script: [Step]
    private let calls = Mutex(0)

    init(kind: WebSearchSourceKind, script: [Step]) {
        self.kind = kind
        self.script = script
    }

    var callCount: Int { calls.withLock { $0 } }

    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        let index = calls.withLock { count in
            defer { count += 1 }
            return count
        }
        switch script[min(index, script.count - 1)] {
        case .found:
            return SearXNGSearchResponse(results: [ChainFixtures.result("Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel")], suggestions: [])
        case .failure(let error):
            throw error
        }
    }
}

/// Seconde passe sur les sources ouvertes (mission E2d) : un échec passager de Wikipédia ne doit pas
/// suffire à répondre « aucune source » à quelqu'un sans clé, sans jamais toucher aux sources payantes.
@MainActor
@Suite("WebSearchChain — seconde passe sur les échecs passagers")
struct WebSearchChainRetryTests {
    private typealias Provider = SequencedWebSearchProvider

    private func chain(
        keyed: [Provider] = [],
        searxng: Provider? = nil,
        cloud: Provider? = nil,
        open: [Provider],
        retry: Duration? = .zero
    ) -> WebSearchChain {
        let base = WebSearchChain(
            keyedProviders: keyed,
            searxng: searxng,
            cloudProvider: cloud,
            openSourceProviders: { _ in open }
        )
        guard let retry else { return base }
        return base.retryingTransientFailures(after: retry)
    }

    private func failures(of work: () async throws -> WebSearchChainResult) async -> [WebSearchSourceFailure] {
        do {
            _ = try await work()
            Issue.record("La chaîne aurait dû lever allSourcesFailed")
        } catch WebSearchChainError.allSourcesFailed(let failures) {
            return failures
        } catch {
            Issue.record("Erreur inattendue : \(error)")
        }
        return []
    }

    // MARK: - Ce que la seconde passe sauve

    @Test("Wikipédia échoue une fois puis répond : la recherche aboutit, SearXNG et Marginalia restent notés")
    func aTransientFailureOfAnOpenSourceIsRescued() async throws {
        let searxng = Provider(kind: .searxng, script: [.failure(.unavailable)])
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.unavailable), .found])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.rateLimited)])

        let result = try await chain(searxng: searxng, open: [wikipedia, marginalia]).search(query: "tour eiffel", options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(!result.response.results.isEmpty)
        #expect(wikipedia.callCount == 2)
        #expect(result.report.passedOver == [
            WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable)),
            WebSearchSourceFailure(source: .marginalia, reason: .searchFailed(.rateLimited)),
        ])
    }

    @Test("Un délai dépassé est aussi réessayé")
    func aTimeoutIsRetriedToo() async throws {
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.timeout), .found])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.timeout)])

        let result = try await chain(open: [wikipedia, marginalia]).search(query: "tour eiffel", options: WebSearchOptions())

        #expect(result.source == .wikipedia)
    }

    // MARK: - Ce qu'elle ne fait jamais

    @Test("Sans activation (défaut), une seule passe : le comportement d'avant")
    func withoutOptInThereIsASinglePass() async {
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.unavailable), .found])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.unavailable)])

        let list = await failures { try await chain(open: [wikipedia, marginalia], retry: nil).search(query: "q", options: WebSearchOptions()) }

        #expect(list.map(\.source) == [.wikipedia, .marginalia])
        #expect(wikipedia.callCount == 1)
    }

    @Test("Une limite de débit (429) n'est pas réessayée : insister l'aggraverait")
    func rateLimitIsNotRetried() async {
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.rateLimited), .found])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.rateLimited)])

        _ = await failures { try await chain(open: [wikipedia, marginalia]).search(query: "q", options: WebSearchOptions()) }

        #expect(wikipedia.callCount == 1)
        #expect(marginalia.callCount == 1)
    }

    @Test("Appareil hors ligne : aucune seconde passe")
    func offlineIsNotRetried() async {
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.noConnection), .found])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.unavailable), .found])

        _ = await failures { try await chain(open: [wikipedia, marginalia]).search(query: "q", options: WebSearchOptions()) }

        #expect(wikipedia.callCount == 1)
        #expect(marginalia.callCount == 1)
    }

    @Test("Clés personnelles, SearXNG et recherche cloud (payante) ne sont jamais réessayés")
    func keyedSearXNGAndCloudSourcesAreNeverRetried() async {
        let brave = Provider(kind: .braveSearch, script: [.failure(.unavailable), .found])
        let searxng = Provider(kind: .searxng, script: [.failure(.timeout), .found])
        let cloud = Provider(kind: .cloudProviderWebSearch, script: [.failure(.unavailable), .found])
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.unavailable)])

        _ = await failures {
            try await chain(keyed: [brave], searxng: searxng, cloud: cloud, open: [wikipedia]).search(query: "q", options: WebSearchOptions())
        }

        #expect(brave.callCount == 1)
        #expect(searxng.callCount == 1)
        #expect(cloud.callCount == 1)
        #expect(wikipedia.callCount == 2)
    }

    @Test("Toujours en échec après la seconde passe : un motif par source, dans l'ordre d'essai, sans doublon")
    func stillFailingReportsOneReasonPerSourceInOrder() async {
        let searxng = Provider(kind: .searxng, script: [.failure(.unavailable)])
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.unavailable), .failure(.timeout)])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.rateLimited)])

        let list = await failures { try await chain(searxng: searxng, open: [wikipedia, marginalia]).search(query: "q", options: WebSearchOptions()) }

        #expect(list == [
            WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable)),
            WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.timeout)),
            WebSearchSourceFailure(source: .marginalia, reason: .searchFailed(.rateLimited)),
        ])
    }

    @Test("Annulation pendant la pause : CancellationError, aucune seconde passe")
    func cancellationDuringThePauseStopsTheChain() async {
        let wikipedia = Provider(kind: .wikipedia, script: [.failure(.unavailable), .found])
        let marginalia = Provider(kind: .marginalia, script: [.failure(.unavailable)])
        let chain = chain(open: [wikipedia, marginalia], retry: .seconds(600))

        let task = Task { try await chain.search(query: "q", options: WebSearchOptions()) }
        // La pause de 10 minutes ne se termine que par l'annulation : on attend que la première passe
        // soit finie (les deux sources interrogées) avant d'annuler, sans durée réelle en jeu.
        while wikipedia.callCount < 1 || marginalia.callCount < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(wikipedia.callCount == 1)
    }

    // MARK: - Le message

    @Test("Hors ligne : se reconnecter")
    func messageWhenOffline() {
        let error = WebSearchChainError.allSourcesFailed([WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.noConnection))])
        #expect(error.userFacingMessage == "Pas de connexion à internet. Reconnecte-toi, puis réessaie.")
    }

    @Test("Un service a répondu (429) : la connexion n'est pas mise en cause")
    func messageWhenAServiceAnswered() {
        let error = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.unavailable)),
            WebSearchSourceFailure(source: .marginalia, reason: .searchFailed(.rateLimited)),
        ])
        #expect(error.reachedAService)
        #expect(!error.userFacingMessage.contains("connexion"))
    }

    @Test("Ni hors ligne ni réponse : réessayer d'abord, la connexion ensuite")
    func messageWhenNothingIsKnown() {
        let error = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.unavailable)),
            WebSearchSourceFailure(source: .marginalia, reason: .searchFailed(.timeout)),
        ])
        #expect(!error.reachedAService)
        #expect(error.userFacingMessage == "Aucune source de recherche n'a répondu. Réessaie dans un instant ; si ça continue, vérifie ta connexion.")
    }
}
