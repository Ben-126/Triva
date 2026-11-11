//
//  WebSearchChainRelevanceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Test lexical dans la chaîne de repli (mission A2, décisions 5 et 6 de Ben) : une source qui ne
/// reprend pas les mots de la question est laissée de côté, la meilleure est gardée si aucune ne
/// passe, et la chaîne le dit (`WebSearchChainReport`). Aucun réseau : sources scénarisées.
@MainActor
@Suite("WebSearchChain — réponses hors sujet")
struct WebSearchChainRelevanceTests {
    private typealias Provider = ScriptedWebSearchProvider

    /// Mots pleins : « hauteur », « tour », « eiffel » ; deux exigés.
    private static let question = "Quelle est la hauteur de la tour Eiffel ?"

    private static let onTopic = [ChainFixtures.result(
        "Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel",
        content: "La tour Eiffel mesure 330 mètres de hauteur."
    )]
    /// Un seul mot repris (« tour ») : hors sujet, rang 1.
    private static let oneWord = [ChainFixtures.result(
        "Tour Montparnasse", url: "https://fr.wikipedia.org/wiki/Tour_Montparnasse",
        content: "Gratte-ciel du 15e arrondissement."
    )]
    /// Un autre article à un seul mot, pour départager à égalité.
    private static let otherOneWord = [ChainFixtures.result(
        "Tour de France", url: "https://fr.wikipedia.org/wiki/Tour_de_France",
        content: "Course cycliste par étapes."
    )]
    /// Aucun mot repris : rang 0.
    private static let noWord = [ChainFixtures.result(
        "Paris Saint-Germain", url: "https://fr.wikipedia.org/wiki/Paris_Saint-Germain",
        content: "Club de football."
    )]

    private func chain(
        keyed: [Provider] = [],
        searxng: Provider? = nil,
        cloud: Provider? = nil,
        open: [Provider] = [],
        unreadable: [WebSearchSourceKind] = []
    ) -> WebSearchChain {
        WebSearchChain(
            keyedProviders: keyed, searxng: searxng, cloudProvider: cloud,
            openSourceProviders: { _ in open }, unreadableKeySources: unreadable
        )
    }

    private func setAside(_ source: WebSearchSourceKind) -> WebSearchSourceFailure {
        WebSearchSourceFailure(source: source, reason: .noUsableAnswer)
    }

    // MARK: - Source suivante

    @Test("SearXNG hors sujet : la chaîne passe à Wikipédia, qui répond sur le sujet, et le note")
    func offTopicSourceIsPassedOver() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(result.response.results == Self.onTopic)
        #expect(result.report == WebSearchChainReport(passedOver: [setAside(.searxng)], matchesQuestion: true))
        #expect(await searxng.callCount == 1)
    }

    @Test("Réponse retenue d'emblée : aucune source suivante interrogée, constat vide")
    func onTopicAnswerStopsTheChain() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.onTopic))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(result.report == WebSearchChainReport())
        #expect(await wikipedia.callCount == 0)
    }

    // MARK: - Aucune source ne passe

    @Test("Rien sur le sujet nulle part : la réponse qui reprend le plus de mots est gardée, et signalée")
    func bestOffTopicAnswerIsKeptAndFlagged() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.oneWord))
        let marginalia = Provider(kind: .marginalia, outcome: .results(Self.noWord))

        let result = try await chain(searxng: searxng, open: [wikipedia, marginalia])
            .search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(result.response.results == Self.oneWord)
        #expect(!result.report.matchesQuestion)
        // La source retenue n'est pas « laissée de côté » : seules les autres y figurent.
        #expect(result.report.passedOver == [setAside(.searxng), setAside(.marginalia)])
        #expect(await marginalia.callCount == 1)
    }

    @Test("À égalité de mots repris, la première dans l'ordre de préférence l'emporte")
    func tieKeepsTheFirstInPreferenceOrder() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.oneWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.otherOneWord))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(result.response.results == Self.oneWord)
        #expect(!result.report.matchesQuestion)
    }

    @Test("Une réponse hors sujet vaut mieux qu'une réponse vide, même plus tardive")
    func offTopicBeatsEmpty() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results([]))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(result.response.results == Self.noWord)
        #expect(!result.report.matchesQuestion)
        #expect(result.report.passedOver == [setAside(.wikipedia)])
    }

    @Test("Toutes à vide : la dernière qui a répondu, comme avant ; rien à signaler sur le sujet")
    func allEmptyKeepsTheLastAnswer() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results([]))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results([]))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(result.response.results.isEmpty)
        #expect(result.report == WebSearchChainReport(passedOver: [setAside(.searxng)], matchesQuestion: true))
    }

    @Test("Échecs et réponse hors sujet : la réponse est rendue, pas d'erreur, les échecs restent notés")
    func failuresAroundAnOffTopicAnswer() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .failure(WebSearchError.unauthorized))
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .failure(WebSearchError.unavailable))

        let result = try await chain(keyed: [brave], searxng: searxng, open: [wikipedia])
            .search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(!result.report.matchesQuestion)
        #expect(result.report.passedOver == [
            WebSearchSourceFailure(source: .braveSearch, reason: .searchFailed(.unauthorized)),
            WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.unavailable)),
        ])
    }

    @Test("Toutes en échec : toujours `allSourcesFailed`, sans motif « sans réponse »")
    func allFailuresStillThrow() async {
        let searxng = Provider(kind: .searxng, outcome: .failure(WebSearchError.unavailable))
        let wikipedia = Provider(kind: .wikipedia, outcome: .failure(WebSearchError.rateLimited))
        let expected = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable)),
            WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.rateLimited)),
        ])

        await #expect(throws: expected) {
            _ = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())
        }
    }

    // MARK: - Cas particuliers

    /// La recherche web du fournisseur cloud rend des URL nues, sans extrait (constat T1) : rien à
    /// comparer, la juger hors sujet la rejetterait toujours.
    @Test("Réponse sans aucun extrait (recherche cloud) : non jugée, retenue")
    func excerptlessAnswerIsRetained() async throws {
        let bare = [SearXNGSearchResult(
            title: "www.ryzlabs.com", url: "https://www.ryzlabs.com", content: nil,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )]
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(bare))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, cloud: cloud, open: [wikipedia])
            .search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .cloudProviderWebSearch)
        #expect(result.report.matchesQuestion)
        #expect(await wikipedia.callCount == 0)
    }

    @Test("Clé illisible puis réponse retenue : la clé figure dans le constat (forme « Vérifier » de l'invitation)")
    func unreadableKeysAreReportedOnSuccess() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, unreadable: [.tavily])
            .search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(result.report.passedOver == [WebSearchSourceFailure(source: .tavily, reason: .keychainUnreadable)])
    }

    @Test("Mode Fiable : un résultat fiable HORS SUJET ne suffit pas, même à côté d'un blog sur le sujet")
    func reliableModeNeedsATrustedOnTopicResult() async throws {
        let trustedOffTopic = Self.noWord
        let untrustedOnTopic = [ChainFixtures.result(
            "Tour Eiffel : sa hauteur", url: "https://blog.example/tour-eiffel", content: "La tour Eiffel et sa hauteur."
        )]
        let searxng = Provider(kind: .searxng, outcome: .results(trustedOffTopic + untrustedOnTopic))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, open: [wikipedia])
            .requiringTrustedDomains(true)
            .search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(result.report.matchesQuestion)
    }

    @Test("Question sans mot plein (« q ») : tout résultat passe, comme avant la mission")
    func questionWithoutContentWordsIsNotJudged() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: "q", options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(await wikipedia.callCount == 0)
    }

    // MARK: - Étape SearXNG : repli sur la recherche générale

    @Test("Académique hors sujet : second appel SearXNG en général, qui répond sur le sujet")
    func specializedOffTopicFallsBackToGeneral() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results([]), outcomesByCategory: [
            .academic: .results(Self.noWord), .general: .results(Self.onTopic),
        ])
        let openAlex = Provider(kind: .openAlex, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, open: [openAlex])
            .search(query: Self.question, options: WebSearchOptions(category: .academic))

        #expect(result.source == .searxng)
        #expect(result.response.results == Self.onTopic)
        #expect(await searxng.categories == [.academic, .general])
        #expect(await openAlex.callCount == 0)
    }

    @Test("Académique sur le sujet : un seul appel SearXNG")
    func specializedOnTopicNeedsNoSecondCall() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.onTopic))

        _ = try await chain(searxng: searxng).search(query: Self.question, options: WebSearchOptions(category: .academic))

        #expect(await searxng.categories == [.academic])
    }

    @Test("Second appel général vide : la réponse spécialisée reste candidate, gardée faute de mieux")
    func emptyGeneralFallbackKeepsTheSpecializedAnswer() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results([]), outcomesByCategory: [
            .discussion: .results(Self.oneWord), .general: .results([]),
        ])

        let result = try await chain(searxng: searxng)
            .search(query: Self.question, options: WebSearchOptions(category: .discussion))

        #expect(result.source == .searxng)
        #expect(result.response.results == Self.oneWord)
        #expect(!result.report.matchesQuestion)
        #expect(await searxng.categories == [.discussion, .general])
    }

    @Test("Recherche générale hors sujet : pas de second appel SearXNG, la chaîne passe à la suite")
    func generalOffTopicDoesNotCallSearXNGTwice() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.noWord))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.onTopic))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: Self.question, options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(await searxng.categories == [.general])
    }
}
