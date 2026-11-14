//
//  DiscoverServicePlanTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/11/2026.
//

import Testing
import Foundation
@testable import Triva

private let french = Locale(identifier: "fr_FR")
private let english = Locale(identifier: "en_US")

/// Un article récent par flux de la langue : de quoi remplir chaque sujet.
private func everyFeedAnswers(delay: Duration? = nil, sourceDelays: [String: Duration] = [:]) -> StubFeedFetcher {
    var behaviors: [String: StubFeedBehavior] = [:]
    for source in DiscoverFeedCatalog.allSources {
        behaviors[source.id] = .items([feedItem(source.id, hoursAgo: 3)])
    }
    return StubFeedFetcher(behaviors, delay: delay, sourceDelays: sourceDelays)
}

@MainActor
@Suite("DiscoverService — nombre de requêtes")
struct DiscoverServiceRequestCountTests {
    @Test("une requête par flux : 8 en français, 9 en anglais, contre 15 à 30 avec SearXNG")
    func oneRequestPerFeed() async {
        for (locale, expected) in [(french, 8), (english, 9)] {
            let fetcher = everyFeedAnswers()
            _ = await makeService(fetcher: fetcher).fetchTrending(locale: locale)
            #expect(fetcher.requestedIDs.count == expected)
            #expect(Set(fetcher.requestedIDs).count == expected, "aucun flux lu deux fois")
        }
    }

    @Test("un appareil en français lit les flux d'ESPN pour le sport, faute de flux français")
    func frenchDeviceReadsEnglishSports() async {
        let fetcher = everyFeedAnswers()
        let content = await makeService(fetcher: fetcher).fetchTrending(locale: french)

        #expect(fetcher.requestedIDs.contains("espn-news"))
        #expect(content.sections.first { $0.topic == .sports }?.articles.first?.sourceName == "ESPN")
    }

    @Test("jamais plus de flux en vol que le plafond", arguments: [1, 3])
    func neverExceedsTheLimit(limit: Int) async {
        let fetcher = everyFeedAnswers(delay: .milliseconds(20))

        _ = await makeService(fetcher: fetcher, maxConcurrentFeeds: limit).fetchTrending(locale: english)

        #expect(fetcher.maxInFlight == limit)
    }
}

@MainActor
@Suite("DiscoverService — échecs")
struct DiscoverServiceFailureTests {
    @Test("un flux en échec ne fait pas tomber les autres sujets")
    func partialFailure() async {
        let fetcher = StubFeedFetcher(
            ["conversation-us-tech": .fails(.network), "conversation-us-finance": .items([feedItem("f", hoursAgo: 1)])],
            fallback: .fails(.badStatus(403))
        )

        let content = await makeService(fetcher: fetcher).fetchTrending(locale: english)

        #expect(content.sections.map(\.topic) == [.finance])
        #expect(content.failedTopics == [.tech, .art, .sports, .entertainment])
    }

    @Test("un sujet dont tous les flux sont trop vieux est en échec, avec le reste intact")
    func staleFeedCountsAsFailed() async {
        let fetcher = StubFeedFetcher(
            ["conversation-us-tech": .items([feedItem("vieux", hoursAgo: 40 * 24)])],
            fallback: .items([feedItem("neuf", hoursAgo: 2)])
        )

        let content = await makeService(fetcher: fetcher).fetchTrending(locale: english)

        #expect(content.failedTopics == [.tech])
        #expect(content.sections.count == 4)
    }

    @Test("hors ligne : tous les sujets échouent, sans exception")
    func offline() async {
        let content = await makeService(fetcher: StubFeedFetcher(fallback: .fails(.network)))
            .fetchTrending(locale: french)

        #expect(content.sections.isEmpty)
        #expect(content.failedTopics == DiscoverTopic.allCases)
    }

    @Test("un seul flux muet parmi plusieurs : le sujet garde les articles des autres")
    func oneSilentFeedAmongSeveral() async {
        let fetcher = StubFeedFetcher(
            ["numerama-tech": .fails(.network), "frandroid": .items([feedItem("fr", hoursAgo: 1)])],
            fallback: .items([])
        )

        let content = await makeService(fetcher: fetcher).fetchTrending(locale: french)

        #expect(content.sections.first { $0.topic == .tech }?.articles.map(\.title) == ["Titre fr"])
    }
}

@MainActor
@Suite("DiscoverService — envoi progressif")
struct DiscoverServiceProgressTests {
    @Test("un flux à la fois : les sujets finissent dans l'ordre du catalogue, chacun une fois")
    func topicsFinishInCatalogOrder() async {
        var finished: [DiscoverTopic] = []

        _ = await makeService(fetcher: everyFeedAnswers(), maxConcurrentFeeds: 1)
            .fetchTrending(locale: french, onTopicFinished: { topic, articles in
                finished.append(topic)
                #expect(!articles.isEmpty)
            })

        #expect(finished == DiscoverTopicCatalog.all.map(\.topic))
    }

    @Test("un sujet en échec est signalé aussi, avec une liste vide")
    func failedTopicsAreReported() async {
        var empties: [DiscoverTopic] = []

        _ = await makeService(fetcher: StubFeedFetcher(fallback: .fails(.badStatus(500))))
            .fetchTrending(locale: french, onTopicFinished: { topic, articles in
                if articles.isEmpty { empties.append(topic) }
            })

        #expect(Set(empties) == Set(DiscoverTopic.allCases))
        #expect(empties.count == DiscoverTopic.allCases.count)
    }

    @Test("les sections du résultat suivent l'ordre du catalogue, pas celui des réponses")
    func sectionsKeepCatalogOrder() async {
        // Le PREMIER sujet du catalogue répond en dernier : chaque sujet attend d'autant moins qu'il est
        // loin dans le catalogue. Avec un même délai pour tous, les flux arrivent dans l'ordre du
        // catalogue, et un retour à l'ordre d'arrivée passerait inaperçu (revue R4-7).
        let plan = makeService(fetcher: StubFeedFetcher()).plannedFeeds(language: .english)
        let topics = DiscoverTopicCatalog.all.map(\.topic)
        var sourceDelays: [String: Duration] = [:]
        for feed in plan {
            let rank = topics.firstIndex(of: feed.topic) ?? 0
            sourceDelays[feed.source.id] = .milliseconds(20 * (topics.count - rank))
        }
        var arrival: [DiscoverTopic] = []

        let content = await makeService(
            fetcher: everyFeedAnswers(sourceDelays: sourceDelays),
            maxConcurrentFeeds: plan.count
        ).fetchTrending(locale: english, onTopicFinished: { topic, _ in arrival.append(topic) })

        // La condition du test : l'arrivée est bien l'INVERSE du catalogue.
        #expect(arrival == topics.reversed())
        #expect(content.sections.map(\.topic) == topics)
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
