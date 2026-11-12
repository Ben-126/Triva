//
//  DiscoverAIUsePolicyTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Politique « pas d'IA sur les articles de certaines sources » (Numerama interdit l'usage de
/// ses articles par une IA pour générer du contenu) : le drapeau `allowsAIUse` voyage du
/// catalogue jusqu'à la ligne d'article, cache disque compris.
@MainActor
@Suite("Découvrir — usage par l'IA des articles")
struct DiscoverAIUsePolicyTests {
    private let item = FeedItem(
        title: "Titre", link: "https://exemple.fr/a", summary: "Extrait", imageURL: nil,
        publishedAt: Date(timeIntervalSince1970: 1_000_000)
    )

    private func source(allowsAIUse: Bool?) -> FeedSource {
        let base = URL(string: "https://exemple.fr/feed") ?? URL(filePath: "/")
        if let allowsAIUse {
            return FeedSource(id: "x", name: "X", url: base, termsURL: base, allowsAIUse: allowsAIUse)
        }
        return FeedSource(id: "x", name: "X", url: base, termsURL: base)
    }

    @Test("une source autorise l'IA par défaut")
    func defaultIsAllowed() {
        let permissive = source(allowsAIUse: nil)
        let strict = source(allowsAIUse: false)
        #expect(permissive.allowsAIUse)
        #expect(!strict.allowsAIUse)
    }

    @Test("Numerama interdit l'IA dans le catalogue, via le drapeau et non via le nom")
    func numeramaIsFlaggedInCatalog() {
        let numerama = DiscoverFeedCatalog.allSources.filter { $0.name == "Numerama" }
        #expect(!numerama.isEmpty)
        #expect(numerama.allSatisfy { !$0.allowsAIUse })
        // Les autres éditeurs n'ont aucune interdiction relevée : l'IA reste permise.
        let others = DiscoverFeedCatalog.allSources.filter { $0.name != "Numerama" }
        #expect(others.allSatisfy { $0.allowsAIUse })
    }

    @Test("l'article hérite du drapeau de sa source")
    func articleInheritsFlag() {
        let forbidden = DiscoverArticle(topic: .tech, item: item, source: source(allowsAIUse: false))
        let allowed = DiscoverArticle(topic: .tech, item: item, source: source(allowsAIUse: true))
        #expect(!forbidden.allowsAIUse)
        #expect(allowed.allowsAIUse)
    }

    @Test("« Chercher dans Triva » n'est proposé que si la source l'autorise et qu'une action existe")
    func searchActionRule() {
        #expect(DiscoverArticlePresentation.offersAISearch(allowsAIUse: true, hasHandler: true))
        #expect(!DiscoverArticlePresentation.offersAISearch(allowsAIUse: false, hasHandler: true))
        #expect(!DiscoverArticlePresentation.offersAISearch(allowsAIUse: true, hasHandler: false))
        #expect(!DiscoverArticlePresentation.offersAISearch(allowsAIUse: false, hasHandler: false))
    }

    @Test("le drapeau survit au cache disque")
    func flagSurvivesCache() throws {
        let forbidden = DiscoverArticle(topic: .tech, item: item, source: source(allowsAIUse: false))
        let allowed = DiscoverArticle(
            topic: .tech, title: "Autre", url: "https://exemple.fr/b", snippet: nil, imageURL: nil
        )
        let content = DiscoverContent(
            sections: [DiscoverTopicSection(topic: .tech, articles: [forbidden, allowed])], failedTopics: []
        )
        let snapshot = DiscoverCacheSnapshot(content: content, dates: [:], fallbackDate: Date())
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(DiscoverCacheSnapshot.self, from: data).restored()
        let articles = try #require(restored.content.sections.first?.articles)
        #expect(articles.count == 2)
        #expect(!articles[0].allowsAIUse)
        #expect(articles[1].allowsAIUse)
    }

    @Test("un cache écrit sans le drapeau est restauré prudemment, IA interdite")
    func legacyCacheIsRestoredAsForbidden() throws {
        let json = """
        {"version":2,"sections":[{"topic":"tech","fetchedAt":0,"articles":[
        {"title":"T","url":"https://exemple.fr/a","sourceName":"Numerama"}]}]}
        """
        let snapshot = try JSONDecoder().decode(DiscoverCacheSnapshot.self, from: Data(json.utf8))
        let article = try #require(snapshot.restored().content.sections.first?.articles.first)
        #expect(!article.allowsAIUse)
    }
}
