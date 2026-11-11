//
//  DiscoverServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Ce que rend un flux factice : des articles, ou une erreur.
nonisolated enum StubFeedBehavior: Sendable {
    case items([FeedItem])
    case fails(FeedFetchError)
}

/// Lecteur de flux factice : rend des articles écrits d'avance pour chaque source (clé :
/// `FeedSource.id`), enregistre les flux demandés et le nombre maximal de lectures
/// simultanées. Une classe à verrou plutôt qu'un acteur : les lectures arrivent en parallèle
/// depuis un `TaskGroup`, et le compilateur refuse ici un acteur conforme à un protocole
/// `nonisolated` avec une init à valeurs par défaut.
final class StubFeedFetcher: FeedFetching, @unchecked Sendable {
    private let behaviors: [String: StubFeedBehavior]
    private let fallback: StubFeedBehavior
    private let delay: Duration?
    private let lock = NSLock()
    private var recordedIDs: [String] = []
    private var currentInFlight = 0
    private var peakInFlight = 0

    init(_ behaviors: [String: StubFeedBehavior] = [:], fallback: StubFeedBehavior = .items([]), delay: Duration? = nil) {
        self.behaviors = behaviors
        self.fallback = fallback
        self.delay = delay
    }

    var requestedIDs: [String] { lock.withLock { recordedIDs } }
    var maxInFlight: Int { lock.withLock { peakInFlight } }

    func items(from source: FeedSource) async throws(FeedFetchError) -> [FeedItem] {
        lock.withLock {
            recordedIDs.append(source.id)
            currentInFlight += 1
            peakInFlight = max(peakInFlight, currentInFlight)
        }
        if let delay { try? await Task.sleep(for: delay) }
        lock.withLock { currentInFlight -= 1 }
        switch behaviors[source.id] ?? fallback {
        case .items(let items): return items
        case .fails(let error): throw error
        }
    }
}

/// Horloge des tests : tout est daté par rapport à elle.
let discoverReferenceNow = Date(timeIntervalSince1970: 1_794_391_200)

func feedItem(_ name: String, hoursAgo: Double?, summary: String? = "Extrait", image: String? = nil) -> FeedItem {
    FeedItem(
        title: "Titre \(name)",
        link: "https://example.test/\(name)",
        summary: summary,
        imageURL: image,
        publishedAt: hoursAgo.map { discoverReferenceNow.addingTimeInterval(-$0 * 3600) }
    )
}

func testSource(_ id: String, usesThumbnails: Bool = true) -> FeedSource {
    FeedSource(
        id: id, name: "Éditeur \(id)",
        url: URL(string: "https://feeds.example.test/\(id).xml") ?? URL(filePath: "/"),
        termsURL: URL(string: "https://example.test/terms") ?? URL(filePath: "/"),
        usesThumbnails: usesThumbnails
    )
}

func makeService(
    fetcher: StubFeedFetcher,
    maxArticlesPerTopic: Int = 12,
    maxConcurrentFeeds: Int = 3
) -> DiscoverService {
    DiscoverService(
        fetcher: fetcher,
        maxArticlesPerTopic: maxArticlesPerTopic,
        maxConcurrentFeeds: maxConcurrentFeeds,
        now: { discoverReferenceNow }
    )
}

@MainActor
@Suite("DiscoverTopicCatalog")
struct DiscoverTopicCatalogTests {
    @Test("chaque sujet a un titre, un symbole et au moins un flux, dans les deux langues (repli compris)")
    func catalogIsFullyPopulated() {
        #expect(DiscoverTopicCatalog.all.count == DiscoverTopic.allCases.count)

        for definition in DiscoverTopicCatalog.all {
            #expect(!definition.title.isEmpty)
            #expect(!definition.systemImage.isEmpty)
            for language in DiscoverLanguage.allCases {
                #expect(
                    !definition.resolvedSources(for: language).sources.isEmpty,
                    "\(definition.topic) n'a aucun flux pour \(language)"
                )
            }
        }
    }

    @Test("chaque sujet du catalogue est unique")
    func noDuplicateTopics() {
        let topics = DiscoverTopicCatalog.all.map(\.topic)
        #expect(Set(topics).count == topics.count)
    }

    @Test("seul le sport utilise l'autre langue, et seulement sur un appareil en français")
    func onlySportsFallsBackToEnglish() {
        for definition in DiscoverTopicCatalog.all {
            #expect(!definition.usesOtherLanguage(than: .english))
            #expect(definition.usesOtherLanguage(than: .french) == (definition.topic == .sports))
        }
    }
}

@MainActor
@Suite("DiscoverLanguage")
struct DiscoverLanguageTests {
    @Test("une locale française sélectionne le français")
    func frenchLocale() {
        #expect(DiscoverLanguage.preferred(for: Locale(identifier: "fr_FR")) == .french)
    }

    @Test("une locale non française sélectionne l'anglais (repli)")
    func nonFrenchLocaleFallsBackToEnglish() {
        #expect(DiscoverLanguage.preferred(for: Locale(identifier: "en_US")) == .english)
        #expect(DiscoverLanguage.preferred(for: Locale(identifier: "de_DE")) == .english)
        #expect(DiscoverLanguage.preferred(for: Locale(identifier: "ja_JP")) == .english)
    }
}

@MainActor
@Suite("DiscoverService — articles d'un sujet")
struct DiscoverServiceArticleTests {
    private func articles(
        _ results: [DiscoverFeedResult],
        max: Int = 12
    ) -> [DiscoverArticle] {
        makeService(fetcher: StubFeedFetcher(), maxArticlesPerTopic: max).articles(for: .tech, from: results)
    }

    @Test("du plus récent au plus ancien, quelle que soit la source")
    func newestFirst() {
        let a = DiscoverFeedResult(source: testSource("a"), items: [feedItem("a1", hoursAgo: 30), feedItem("a2", hoursAgo: 2)])
        let b = DiscoverFeedResult(source: testSource("b"), items: [feedItem("b1", hoursAgo: 10)])

        #expect(articles([a, b]).map(\.url) == [
            "https://example.test/a2", "https://example.test/b1", "https://example.test/a1",
        ])
    }

    @Test("un article sans date, trop ancien ou daté du futur lointain est écarté (findings Q3 28 et 53)")
    func datesAreRequired() {
        let result = DiscoverFeedResult(source: testSource("a"), items: [
            feedItem("recent", hoursAgo: 5),
            feedItem("sansdate", hoursAgo: nil),
            feedItem("ancien", hoursAgo: 22 * 24),
            feedItem("limite", hoursAgo: 20 * 24),
            feedItem("futur", hoursAgo: -48),
            feedItem("demain", hoursAgo: -3),
        ])

        #expect(articles([result]).map(\.title) == [
            "Titre demain", "Titre recent", "Titre limite",
        ])
    }

    @Test("le même article dans deux flux n'apparaît qu'une fois")
    func deduplicatesAcrossSources() {
        let a = DiscoverFeedResult(source: testSource("a"), items: [feedItem("x", hoursAgo: 1), feedItem("y", hoursAgo: 3)])
        let b = DiscoverFeedResult(source: testSource("b"), items: [feedItem("x", hoursAgo: 1)])

        #expect(articles([a, b]).map(\.url) == ["https://example.test/x", "https://example.test/y"])
    }

    @Test("le nombre d'articles par sujet est borné")
    func boundsArticles() {
        let items = (0..<30).map { feedItem("n\($0)", hoursAgo: Double($0) + 1) }
        let result = DiscoverFeedResult(source: testSource("a"), items: items)

        #expect(articles([result]).count == 12)
        #expect(articles([result], max: 5).map(\.title) == (0..<5).map { "Titre n\($0)" })
    }

    @Test("un flux bavard ne chasse pas les autres : chacun a sa part, les places libres vont aux plus récents")
    func eachSourceKeepsItsShare() {
        let chatty = DiscoverFeedResult(
            source: testSource("chatty"),
            items: (0..<20).map { feedItem("c\($0)", hoursAgo: Double($0) + 1) }
        )
        let quiet = DiscoverFeedResult(
            source: testSource("quiet"),
            items: (0..<3).map { feedItem("q\($0)", hoursAgo: 100 + Double($0)) }
        )

        let chosen = articles([chatty, quiet])

        // 3 de la source discrète (anciennes mais présentes) + 9 de la bavarde = 12.
        #expect(chosen.count == 12)
        #expect(chosen.filter { $0.sourceName == "Éditeur quiet" }.count == 3)
        #expect(chosen.filter { $0.sourceName == "Éditeur chatty" }.count == 9)
    }

    @Test("sans vignette garantie, l'image du flux n'est pas gardée (The Conversation)")
    func thumbnailsFollowTheSourcePolicy() throws {
        let image = "https://images.example/a.jpg"
        let allowed = DiscoverFeedResult(source: testSource("a"), items: [feedItem("a", hoursAgo: 1, image: image)])
        let denied = DiscoverFeedResult(
            source: testSource("b", usesThumbnails: false),
            items: [feedItem("b", hoursAgo: 2, image: image)]
        )

        let chosen = articles([allowed, denied])

        #expect(try #require(chosen.first { $0.url.hasSuffix("/a") }).imageURL?.absoluteString == image)
        #expect(try #require(chosen.first { $0.url.hasSuffix("/b") }).imageURL == nil)
    }

    @Test("chaque article porte l'éditeur et la date réelle")
    func articlesCarrySourceAndDate() throws {
        let result = DiscoverFeedResult(source: testSource("a"), items: [feedItem("a", hoursAgo: 4, summary: "Résumé")])

        let article = try #require(articles([result]).first)

        #expect(article.sourceName == "Éditeur a")
        #expect(article.publishedAt == discoverReferenceNow.addingTimeInterval(-4 * 3600))
        #expect(article.snippet == "Résumé")
    }

    @Test("un flux en échec (nil) ne retire rien aux autres")
    func failedSourceIsIgnored() {
        let ok = DiscoverFeedResult(source: testSource("a"), items: [feedItem("a", hoursAgo: 1)])
        let failed = DiscoverFeedResult(source: testSource("b"), items: nil)

        #expect(articles([failed, ok]).count == 1)
    }

    @Test("l'ordre est identique à chaque appel : pas de mélange")
    func orderIsStable() {
        let items = (0..<8).map { feedItem("s\($0)", hoursAgo: 5) }
        let result = DiscoverFeedResult(source: testSource("a"), items: items)

        let first = articles([result]).map(\.url)
        let second = articles([result]).map(\.url)

        #expect(first == second)
        #expect(first == first.sorted())
    }
}
