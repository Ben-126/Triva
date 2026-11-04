//
//  DiscoverServicePlanTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Compte les requêtes et le maximum en vol. `delay` laisse les recherches se
/// chevaucher : sans lui, le plafond ne serait jamais mis à l'épreuve.
private actor CountingClient: SearXNGSearching {
    enum Behavior: Sendable {
        case results
        case emptyNews
        case throwsError
        /// Lève pour cette requête, répond pour les autres.
        case failsOn(String)
    }

    private let behavior: Behavior
    private let delay: Duration
    private(set) var options: [SearXNGSearchOptions] = []
    private(set) var queries: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0

    init(_ behavior: Behavior, delay: Duration = .zero) {
        self.behavior = behavior
        self.delay = delay
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        self.options.append(options)
        queries.append(query)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        inFlight -= 1
        let hit = SearXNGSearchResult(
            title: "Titre", url: "https://example.com/\(queries.count)", content: nil,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
        switch behavior {
        case .results:
            return SearXNGSearchResponse(results: [hit], suggestions: [])
        case .emptyNews:
            return SearXNGSearchResponse(results: options.categories.isEmpty ? [hit] : [], suggestions: [])
        case .throwsError:
            throw URLError(.badServerResponse)
        case .failsOn(let failing):
            if query == failing { throw URLError(.badServerResponse) }
            return SearXNGSearchResponse(results: [hit], suggestions: [])
        }
    }
}

@MainActor
private func makeService(
    client: any SearXNGSearching,
    catalog: [DiscoverTopicDefinition] = DiscoverTopicCatalog.all,
    maxConcurrentSearches: Int = DiscoverService.defaultMaxConcurrentSearches
) -> DiscoverService {
    DiscoverService(
        failoverManager: FailoverManager(client: client, instances: [URL(string: "https://searx.example")!]),
        catalog: catalog,
        maxConcurrentSearches: maxConcurrentSearches
    )
}

private let locales: [String] = ["fr_FR", "en_US"]

@MainActor
@Suite("DiscoverService — nombre de requêtes")
struct DiscoverServiceRequestBudgetTests {
    /// Le chiffre de la mission : 15 requêtes sur le vrai catalogue, dans les deux langues.
    @Test("le catalogue réel coûte exactement 15 requêtes quand les instances répondent", arguments: locales)
    func realCatalogCostsFifteenRequests(locale: String) async {
        let client = CountingClient(.results)

        let content = await makeService(client: client).fetchTrending(locale: Locale(identifier: locale))

        #expect(await client.queries.count == 15)
        #expect(content.sections.count == DiscoverTopic.allCases.count)
    }

    @Test("sans résultat en catégorie news : le repli double au plus, 30 requêtes", arguments: locales)
    func emptyNewsCostsAtMostThirty(locale: String) async {
        let client = CountingClient(.emptyNews)

        _ = await makeService(client: client).fetchTrending(locale: Locale(identifier: locale))

        #expect(await client.queries.count == 30)
    }

    @Test("une erreur ne relance pas le repli sans catégorie")
    func errorDoesNotTriggerFallback() async {
        let client = CountingClient(.throwsError)
        let definition = DiscoverTopicCatalog.all[0]

        _ = await makeService(client: client, catalog: [definition], maxConcurrentSearches: 1)
            .fetchTrending(locale: Locale(identifier: "fr_FR"))

        #expect(await client.options.allSatisfy { $0.categories == ["news"] })
    }

    @Test("toutes les instances refusent : le chargement s'arrête au lieu d'envoyer les 15 recherches")
    func stopsWhenEverySearchIsRefused() async {
        let client = CountingClient(.throwsError)

        let content = await makeService(client: client).fetchTrending(locale: Locale(identifier: "fr_FR"))

        // Au pire, les recherches déjà en vol s'ajoutent à celles qui font renoncer.
        let threshold = DiscoverService.failedSearchesBeforeStopping
        let sent = await client.queries.count
        #expect(sent >= threshold)
        #expect(sent < threshold + DiscoverService.defaultMaxConcurrentSearches, "\(sent) requêtes pour une seule instance")
        #expect(content.sections.isEmpty)
        #expect(content.failedTopics.count == DiscoverTopic.allCases.count)
    }

    /// Un refus passager ne doit pas priver tous les sujets : c'est tout l'intérêt
    /// du seuil.
    @Test("un seul échec, puis des réponses : les autres sujets arrivent quand même")
    func singleFailureDoesNotStopTheLoad() async {
        let plan = makeService(client: CountingClient(.results)).plannedSearches(language: .french)
        let first = plan[0]
        let client = CountingClient(.failsOn("site:\(first.domain) \(first.query)"))
        let definitions = DiscoverTopicCatalog.all.map { definition in
            DiscoverTopicDefinition(
                topic: definition.topic,
                title: definition.title,
                systemImage: definition.systemImage,
                localizedContentByLanguage: [.french: DiscoverLocalizedTopicContent(
                    queries: [first.query],
                    domains: definition.topic == first.topic ? [first.domain] : ["\(definition.id).example"]
                )]
            )
        }

        let content = await makeService(client: client, catalog: definitions, maxConcurrentSearches: 1)
            .fetchTrending(locale: Locale(identifier: "fr_FR"))

        #expect(content.failedTopics == [first.topic])
        #expect(content.sections.count == DiscoverTopic.allCases.count - 1)
    }
}

@MainActor
@Suite("DiscoverService — envoi progressif")
struct DiscoverServiceProgressTests {
    @Test("jamais plus de recherches en vol que le plafond", arguments: [1, 3])
    func neverExceedsTheLimit(limit: Int) async {
        let client = CountingClient(.results, delay: .milliseconds(20))

        _ = await makeService(client: client, maxConcurrentSearches: limit)
            .fetchTrending(locale: Locale(identifier: "fr_FR"))

        #expect(await client.maxInFlight == limit)
    }

    @Test("une recherche à la fois : les sujets finissent dans l'ordre du catalogue, chacun une fois")
    func topicsFinishInCatalogOrder() async {
        var finished: [DiscoverTopic] = []

        _ = await makeService(client: CountingClient(.results), maxConcurrentSearches: 1)
            .fetchTrending(locale: Locale(identifier: "fr_FR"), onTopicFinished: { topic, articles in
                finished.append(topic)
                #expect(!articles.isEmpty)
            })

        #expect(finished == DiscoverTopicCatalog.all.map(\.topic))
    }

    @Test("un sujet en échec est signalé aussi, avec une liste vide")
    func failedTopicsAreReported() async {
        var empties: [DiscoverTopic] = []

        _ = await makeService(client: CountingClient(.throwsError))
            .fetchTrending(locale: Locale(identifier: "fr_FR"), onTopicFinished: { topic, articles in
                if articles.isEmpty { empties.append(topic) }
            })

        #expect(Set(empties) == Set(DiscoverTopic.allCases))
        #expect(empties.count == DiscoverTopic.allCases.count)
    }
}

@MainActor
@Suite("DiscoverService — variété des recherches")
struct DiscoverServiceVarietyTests {
    private let content = DiscoverLocalizedTopicContent(
        queries: ["q0", "q1", "q2", "q3"],
        domains: ["a.example", "b.example", "c.example"]
    )

    @Test("trois recherches : chaque domaine une fois, avec des requêtes différentes")
    func everyDomainOnceWithDistinctQueries() {
        let searches = DiscoverService.searches(for: content, rotation: 0)
        #expect(searches.map(\.domain) == content.domains)
        #expect(Set(searches.map(\.query)).count == 3)
    }

    @Test("au fil des chargements, toutes les requêtes finissent par servir")
    func rotationCoversEveryQuery() {
        let used = (0..<content.queries.count).flatMap { rotation in
            DiscoverService.searches(for: content, rotation: rotation).map(\.query)
        }
        #expect(Set(used) == Set(content.queries))
    }

    @Test("chaque sujet du catalogue, dans chaque langue, garde tous ses domaines")
    func catalogKeepsEveryDomain() {
        for definition in DiscoverTopicCatalog.all {
            for language in DiscoverLanguage.allCases {
                let localized = definition.localizedContent(for: language)
                let searches = DiscoverService.searches(for: localized, rotation: 7)
                #expect(searches.count == DiscoverService.combosPerTopic)
                #expect(Set(searches.map(\.domain)) == Set(localized.domains))
            }
        }
    }

    @Test("catalogue réduit : pas de doublon, jamais plus que ce qui existe")
    func smallCatalogHasNoDuplicates() {
        let one = DiscoverLocalizedTopicContent(queries: ["q"], domains: ["a.example"])
        #expect(DiscoverService.searches(for: one, rotation: 3).count == 1)
        let two = DiscoverLocalizedTopicContent(queries: ["q0", "q1"], domains: ["a.example"])
        #expect(Set(DiscoverService.searches(for: two, rotation: 1).map(\.query)) == ["q0", "q1"])
        let none = DiscoverLocalizedTopicContent(queries: [], domains: ["a.example"])
        #expect(DiscoverService.searches(for: none, rotation: 0).isEmpty)
    }
}

@MainActor
@Suite("DiscoverLanguage — langue de l'appareil")
struct DiscoverDeviceLanguageTests {
    @Test("suit la première langue préférée, pas la langue de l'app")
    func followsPreferredLanguages() {
        #expect(DiscoverLanguage.device(preferredLanguages: ["fr-FR", "en-US"]) == .french)
        #expect(DiscoverLanguage.device(preferredLanguages: ["fr-CA"]) == .french)
        #expect(DiscoverLanguage.device(preferredLanguages: ["en-GB", "fr-FR"]) == .english)
        #expect(DiscoverLanguage.device(preferredLanguages: ["de-DE"]) == .english)
        #expect(DiscoverLanguage.device(preferredLanguages: []) == .english)
    }
}
