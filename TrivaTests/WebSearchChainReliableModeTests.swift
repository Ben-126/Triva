//
//  WebSearchChainReliableModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Mode Fiable de la chaîne de repli (décision de Ben) : une source ne suffit que si l'un de ses
/// résultats passe le filtre de domaines. Aucun réseau : sources scénarisées.
@MainActor
@Suite("WebSearchChain — mode Fiable")
struct WebSearchChainReliableModeTests {
    private typealias Provider = ScriptedWebSearchProvider

    private static let untrusted = [ChainFixtures.result("Blog", url: "https://blog.example/page")]
    private static let trusted = [ChainFixtures.result("Wiki", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel")]
    private static let mixed = untrusted + trusted

    private func chain(keyed: [Provider] = [], searxng: Provider? = nil, cloud: Provider? = nil, open: [Provider] = []) -> WebSearchChain {
        WebSearchChain(keyedProviders: keyed, searxng: searxng, cloudProvider: cloud, openSourceProviders: { _ in open })
    }

    @Test("Aucun résultat fiable : la chaîne passe à la source suivante, jusqu'à Wikipédia")
    func movesOnUntilATrustedResult() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(Self.untrusted))
        let searxng = Provider(kind: .searxng, outcome: .results(Self.untrusted))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.trusted))

        let result = try await chain(keyed: [brave], searxng: searxng, open: [wikipedia])
            .requiringTrustedDomains(true)
            .search(query: "q", options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(result.response.results == Self.trusted)
        #expect(await brave.callCount == 1)
        #expect(await searxng.callCount == 1)
    }

    @Test("Arrêt dès qu'un résultat passe le filtre : la réponse reste entière, le classement filtrera")
    func stopsAtTheFirstTrustedResult() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.mixed))
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.trusted))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.trusted))

        let result = try await chain(searxng: searxng, cloud: cloud, open: [wikipedia])
            .requiringTrustedDomains(true)
            .search(query: "q", options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(result.response.results == Self.mixed)
        #expect(await cloud.callCount == 0)
        #expect(await wikipedia.callCount == 0)
    }

    @Test("Étape cloud payante : atteinte à son rang normal, après SearXNG et avant les sources ouvertes")
    func thePaidStepKeepsItsRank() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.trusted))
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.trusted))
        _ = try await chain(searxng: searxng, cloud: cloud).requiringTrustedDomains(true)
            .search(query: "q", options: WebSearchOptions())
        #expect(await cloud.callCount == 0)

        let untrustedSearxng = Provider(kind: .searxng, outcome: .results(Self.untrusted))
        let reachedCloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.trusted))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.trusted))
        let result = try await chain(searxng: untrustedSearxng, cloud: reachedCloud, open: [wikipedia])
            .requiringTrustedDomains(true)
            .search(query: "q", options: WebSearchOptions())
        #expect(result.source == .cloudProviderWebSearch)
        #expect(await wikipedia.callCount == 0)
    }

    @Test("Rien de fiable nulle part : toutes interrogées, dernière réponse rendue, pas d'erreur")
    func nothingTrustedAnywhereIsNotAnError() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(Self.untrusted))
        let marginalia = Provider(kind: .marginalia, outcome: .results(Self.untrusted))

        let result = try await chain(keyed: [brave], open: [marginalia])
            .requiringTrustedDomains(true)
            .search(query: "q", options: WebSearchOptions())

        #expect(result.source == .marginalia)
        #expect(await brave.callCount == 1)
        #expect(await marginalia.callCount == 1)
    }

    @Test("Réponse sans domaine fiable puis source en échec : réponse rendue, pas d'échec total")
    func anAnswerFollowedByAFailureIsNotATotalFailure() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.untrusted))
        let wikipedia = Provider(kind: .wikipedia, outcome: .failure(WebSearchError.unavailable))

        let result = try await chain(searxng: searxng, open: [wikipedia])
            .requiringTrustedDomains(true)
            .search(query: "q", options: WebSearchOptions())

        #expect(result.source == .searxng)
    }

    @Test("Hors mode Fiable : inchangé, la première réponse non vide gagne")
    func otherModesStopAtTheFirstAnswer() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.untrusted))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.trusted))

        for candidate in [chain(searxng: searxng, open: [wikipedia]), chain(searxng: searxng, open: [wikipedia]).requiringTrustedDomains(false)] {
            let result = try await candidate.search(query: "q", options: WebSearchOptions())
            #expect(result.source == .searxng)
        }
        #expect(await wikipedia.callCount == 0)
    }

    @Test("Annulation pendant une source : arrêt net, la source suivante (cloud payant) n'est pas appelée")
    func cancellationStopsTheChain() async {
        let searxng = Provider(kind: .searxng, outcome: .waitForCancellation)
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.trusted))
        let chain = chain(searxng: searxng, cloud: cloud).requiringTrustedDomains(true)

        let task = Task { try await chain.search(query: "q", options: WebSearchOptions()) }
        await ChainFixtures.waitUntil("SearXNG interrogé") { await searxng.callCount == 1 }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cloud.callCount == 0)
    }
}
