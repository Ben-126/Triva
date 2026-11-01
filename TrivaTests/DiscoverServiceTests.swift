//
//  DiscoverServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/09/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockError: Error, Sendable, Equatable {
    case searchFailed
}

/// Client SearXNG factice : `provider` décide des résultats à renvoyer pour
/// une combinaison (query, options) donnée — nécessaire ici plutôt qu'une
/// simple table `[query: résultats]` comme dans `SearchOrchestratorTests`
/// car `DiscoverService.searchOneCombo` interroge parfois la MÊME requête
/// texte deux fois avec des `options` différentes (repli catégorie `news` ->
/// sans restriction), et les tests doivent pouvoir distinguer les deux
/// tentatives.
private actor MockDiscoverSearXNGClient: SearXNGSearching {
    private let provider: @Sendable (String, SearXNGSearchOptions) -> [SearXNGSearchResult]
    private let failingQueries: Set<String>
    private(set) var recordedQueries: [String] = []
    private(set) var recordedOptions: [SearXNGSearchOptions] = []

    init(
        failingQueries: Set<String> = [],
        provider: @escaping @Sendable (String, SearXNGSearchOptions) -> [SearXNGSearchResult] = { _, _ in [] }
    ) {
        self.failingQueries = failingQueries
        self.provider = provider
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        recordedQueries.append(query)
        recordedOptions.append(options)
        if failingQueries.contains(query) {
            throw MockError.searchFailed
        }
        return SearXNGSearchResponse(results: provider(query, options), suggestions: [])
    }
}

/// Mélangeur factice déterministe : identité par défaut, pour que les tests
/// de dédup/bornage n'aient pas à composer avec un ordre aléatoire.
private struct IdentityShuffler: DiscoverArticleShuffling {
    func shuffled(_ articles: [DiscoverArticle]) -> [DiscoverArticle] { articles }
}

private func result(_ url: String, title: String = "Titre") -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: title,
        url: url,
        content: "Extrait",
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

private let dummyInstance = URL(string: "https://searx.example")!

private func makeFailoverManager(client: any SearXNGSearching) -> FailoverManager {
    FailoverManager(client: client, instances: [dummyInstance])
}

@MainActor
@Suite("DiscoverTopicCatalog")
struct DiscoverTopicCatalogTests {
    @Test("aucun sujet n'a de domaine ou de requête vide, dans aucune langue")
    func catalogIsFullyPopulated() {
        #expect(DiscoverTopicCatalog.all.count == DiscoverTopic.allCases.count)

        for definition in DiscoverTopicCatalog.all {
            #expect(!definition.title.isEmpty)
            #expect(!definition.systemImage.isEmpty)
            for language in DiscoverLanguage.allCases {
                let content = definition.localizedContent(for: language)
                #expect(!content.queries.isEmpty, "\(definition.topic) n'a aucune requête pour \(language)")
                #expect(!content.domains.isEmpty, "\(definition.topic) n'a aucun domaine pour \(language)")
                #expect(content.queries.allSatisfy { !$0.isEmpty })
                #expect(content.domains.allSatisfy { !$0.isEmpty })
            }
        }
    }

    @Test("chaque sujet du catalogue est unique")
    func noDuplicateTopics() {
        let topics = DiscoverTopicCatalog.all.map(\.topic)
        #expect(Set(topics).count == topics.count)
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
@Suite("DiscoverService")
struct DiscoverServiceTests {
    private func singleDomainTopic(
        _ topic: DiscoverTopic,
        domain: String,
        query: String
    ) -> DiscoverTopicDefinition {
        let content = DiscoverLocalizedTopicContent(queries: [query], domains: [domain])
        return DiscoverTopicDefinition(
            topic: topic,
            title: topic.rawValue,
            systemImage: "star",
            localizedContentByLanguage: [.english: content, .french: content]
        )
    }

    @Test("construit la requête site:<domaine> <mot-clé>")
    func buildsSiteScopedQuery() async {
        let client = MockDiscoverSearXNGClient()
        let definition = singleDomainTopic(.tech, domain: "example.com", query: "actualité")
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: [definition]
        )

        _ = await service.fetchTrending(locale: Locale(identifier: "fr_FR"))

        let queries = await client.recordedQueries
        #expect(queries.contains("site:example.com actualité"))
    }

    @Test("sélectionne les domaines/requêtes FR pour une locale française, EN sinon")
    func selectsDomainsByLocale() async {
        let content = { (label: String) in
            DiscoverLocalizedTopicContent(queries: ["\(label)-query"], domains: ["\(label)-domain.example"])
        }
        let definition = DiscoverTopicDefinition(
            topic: .tech,
            title: "Tech",
            systemImage: "cpu",
            localizedContentByLanguage: [.french: content("fr"), .english: content("en")]
        )

        // Le mock DOIT renvoyer un résultat : avec le provider par défaut (liste
        // vide), `DiscoverService` applique son repli "réessayer sans restriction
        // de catégorie" (voir `fallsBackWhenNewsCategoryEmpty`) et la même requête
        // est alors enregistrée DEUX fois, ce qui ferait échouer l'égalité stricte
        // ci-dessous sans aucun rapport avec le choix de domaine par locale.
        let frenchClient = MockDiscoverSearXNGClient(provider: { _, _ in [result("https://fr-domain.example/a")] })
        let frenchService = DiscoverService(
            failoverManager: makeFailoverManager(client: frenchClient),
            shuffler: IdentityShuffler(),
            catalog: [definition]
        )
        _ = await frenchService.fetchTrending(locale: Locale(identifier: "fr_FR"))
        let frenchQueries = await frenchClient.recordedQueries
        #expect(frenchQueries == ["site:fr-domain.example fr-query"])

        let englishClient = MockDiscoverSearXNGClient(provider: { _, _ in [result("https://en-domain.example/a")] })
        let englishService = DiscoverService(
            failoverManager: makeFailoverManager(client: englishClient),
            shuffler: IdentityShuffler(),
            catalog: [definition]
        )
        _ = await englishService.fetchTrending(locale: Locale(identifier: "en_US"))
        let englishQueries = await englishClient.recordedQueries
        #expect(englishQueries == ["site:en-domain.example en-query"])
    }

    @Test("retente sans restriction de catégorie si la catégorie news ne renvoie rien")
    func fallsBackWhenNewsCategoryEmpty() async {
        let client = MockDiscoverSearXNGClient(provider: { _, options in
            options.categories.isEmpty ? [result("https://example.com/article")] : []
        })
        let definition = singleDomainTopic(.tech, domain: "example.com", query: "news")
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: [definition]
        )

        let content = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        #expect(content.sections.first?.articles.map(\.url) == ["https://example.com/article"])
        let options = await client.recordedOptions
        #expect(options.count == 2, "doit avoir tenté la catégorie news PUIS le repli")
        #expect(options[0].categories == ["news"])
        #expect(options[1].categories.isEmpty)
    }

    @Test("ne retente pas le repli si la catégorie news a déjà des résultats")
    func doesNotFallBackWhenNewsCategorySucceeds() async {
        let client = MockDiscoverSearXNGClient(provider: { _, options in
            options.categories == ["news"] ? [result("https://example.com/article")] : []
        })
        let definition = singleDomainTopic(.tech, domain: "example.com", query: "news")
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: [definition]
        )

        _ = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        let options = await client.recordedOptions
        #expect(options.count == 1)
    }

    @Test("déduplique par URL normalisée (casse et espaces ignorés)")
    func deduplicatesByNormalizedURL() async {
        let content = DiscoverLocalizedTopicContent(
            queries: ["q1", "q2"],
            domains: ["example.com"]
        )
        let definition = DiscoverTopicDefinition(
            topic: .tech,
            title: "Tech",
            systemImage: "cpu",
            localizedContentByLanguage: [.english: content, .french: content]
        )
        let client = MockDiscoverSearXNGClient(provider: { query, _ in
            switch query {
            case "site:example.com q1":
                return [result("https://Example.com/Article ")]
            case "site:example.com q2":
                return [result(" https://example.com/article")]
            default:
                return []
            }
        })
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: [definition]
        )

        let discovered = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        #expect(discovered.sections.count == 1)
        #expect(discovered.sections.first?.articles.count == 1)
    }

    @Test("borne le nombre d'articles par sujet")
    func boundsArticlesPerTopic() async {
        let urls = (0..<20).map { "https://example.com/article-\($0)" }
        let content = DiscoverLocalizedTopicContent(queries: ["news"], domains: ["example.com"])
        let definition = DiscoverTopicDefinition(
            topic: .tech,
            title: "Tech",
            systemImage: "cpu",
            localizedContentByLanguage: [.english: content, .french: content]
        )
        let client = MockDiscoverSearXNGClient(provider: { _, _ in urls.map { result($0) } })
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: [definition],
            maxArticlesPerTopic: 5
        )

        let discovered = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        #expect(discovered.sections.first?.articles.count == 5)
    }

    @Test("un sujet en échec total n'empêche pas les autres de remonter")
    func partialTopicFailureDoesNotSinkOthers() async {
        let workingTopic = singleDomainTopic(.tech, domain: "working.example", query: "news")
        let failingTopic = singleDomainTopic(.finance, domain: "failing.example", query: "news")

        let client = MockDiscoverSearXNGClient(
            failingQueries: ["site:failing.example news"],
            provider: { query, _ in
                query == "site:working.example news" ? [result("https://working.example/a")] : []
            }
        )
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: [workingTopic, failingTopic]
        )

        let discovered = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        #expect(discovered.sections.map(\.topic) == [.tech])
        #expect(discovered.failedTopics == [.finance])
    }

    @Test("aucune donnée disponible -> aucune section, tous les sujets en échec")
    func noDataAvailable() async {
        let definitions = [
            singleDomainTopic(.tech, domain: "a.example", query: "news"),
            singleDomainTopic(.finance, domain: "b.example", query: "news"),
        ]
        let client = MockDiscoverSearXNGClient(provider: { _, _ in [] })
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: definitions
        )

        let discovered = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        #expect(discovered.sections.isEmpty)
        #expect(Set(discovered.failedTopics) == Set([.tech, .finance]))
    }

    @Test("conserve l'ordre du catalogue, pas l'ordre de complétion réseau")
    func preservesCatalogOrder() async {
        let definitions = [
            singleDomainTopic(.entertainment, domain: "e.example", query: "news"),
            singleDomainTopic(.tech, domain: "t.example", query: "news"),
            singleDomainTopic(.sports, domain: "s.example", query: "news"),
        ]
        let client = MockDiscoverSearXNGClient(provider: { query, _ in
            [result("https://\(query).example/a")]
        })
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: IdentityShuffler(),
            catalog: definitions
        )

        let discovered = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        #expect(discovered.sections.map(\.topic) == [.entertainment, .tech, .sports])
    }

    @Test("l'aléa injecté est bien utilisé pour ordonner les articles")
    func usesInjectedRandomness() async {
        struct ReversingShuffler: DiscoverArticleShuffling {
            func shuffled(_ articles: [DiscoverArticle]) -> [DiscoverArticle] { articles.reversed() }
        }

        let content = DiscoverLocalizedTopicContent(queries: ["q1", "q2"], domains: ["example.com"])
        let definition = DiscoverTopicDefinition(
            topic: .tech,
            title: "Tech",
            systemImage: "cpu",
            localizedContentByLanguage: [.english: content, .french: content]
        )
        let client = MockDiscoverSearXNGClient(provider: { query, _ in
            switch query {
            case "site:example.com q1": return [result("https://example.com/first")]
            case "site:example.com q2": return [result("https://example.com/second")]
            default: return []
            }
        })
        let service = DiscoverService(
            failoverManager: makeFailoverManager(client: client),
            shuffler: ReversingShuffler(),
            catalog: [definition]
        )

        let discovered = await service.fetchTrending(locale: Locale(identifier: "en_US"))

        let urls = discovered.sections.first?.articles.map(\.url) ?? []
        #expect(Set(urls) == Set(["https://example.com/first", "https://example.com/second"]))
    }
}
