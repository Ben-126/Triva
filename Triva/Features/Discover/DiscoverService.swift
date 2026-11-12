//
//  DiscoverService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Un article de Découvrir, prêt pour l'affichage. Venu d'un flux RSS/Atom (`FeedItem`),
/// recadré sur ce dont l'écran a besoin : `id` déjà normalisé, qui sert à la fois de clé
/// `Identifiable` et de clé de déduplication, `imageURL` déjà parsée.
///
/// `nonisolated` : donnée pure, construite par `DiscoverService` hors du main actor. Sans
/// cela, chaque création d'article reviendrait sur le fil principal.
nonisolated struct DiscoverArticle: Sendable, Equatable, Identifiable {
    let id: String
    let topic: DiscoverTopic
    let title: String
    let url: String
    let snippet: String?
    let imageURL: URL?
    /// Date de publication fournie par l'éditeur. `nil` seulement pour un article écrit à
    /// la main (aperçus, tests) : `DiscoverService` n'en produit jamais sans date.
    let publishedAt: Date?
    /// Nom de l'éditeur (« Numerama »), cité sous chaque article comme l'exigent les
    /// conditions de plusieurs flux (ESPN, PMC).
    let sourceName: String?
    /// Faux si la source interdit l'usage de ses articles par une IA (`FeedSource.allowsAIUse`) :
    /// l'interface ne propose alors aucune action qui enverrait l'article, ou son titre, à l'IA.
    let allowsAIUse: Bool

    init(topic: DiscoverTopic, item: FeedItem, source: FeedSource) {
        self.init(
            topic: topic,
            title: item.title,
            url: item.link,
            snippet: item.summary,
            imageURL: source.usesThumbnails ? item.imageURL.flatMap { URL(string: $0) } : nil,
            publishedAt: item.publishedAt,
            sourceName: source.name,
            allowsAIUse: source.allowsAIUse
        )
    }

    /// Article restauré du cache (`DiscoverCacheSnapshot.restored()`) ou écrit à la main
    /// (aperçus, tests).
    init(
        topic: DiscoverTopic,
        title: String,
        url: String,
        snippet: String?,
        imageURL: URL?,
        publishedAt: Date? = nil,
        sourceName: String? = nil,
        allowsAIUse: Bool = true
    ) {
        self.topic = topic
        self.title = title
        self.url = url
        self.snippet = snippet
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.sourceName = sourceName
        self.allowsAIUse = allowsAIUse
        self.id = Self.normalizedKey(for: url)
    }

    /// Même règle de déduplication que le web (`item.url?.toLowerCase().trim()`,
    /// route.ts) : suffisant pour éliminer le même article repris par deux flux d'un même
    /// sujet (ESPN « news » et « soccer »), pas une normalisation d'URL complète.
    static func normalizedKey(for url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Les articles collectés pour un sujet, dans l'ordre du catalogue
/// (`DiscoverContent.sections`), pas dans l'ordre d'arrivée réseau — un
/// `TaskGroup` complète ses tâches dans un ordre non déterministe, et une UI
/// dont les sections sautent de place à chaque rafraîchissement serait
/// désorientante.
nonisolated struct DiscoverTopicSection: Sendable, Equatable, Identifiable {
    let topic: DiscoverTopic
    let articles: [DiscoverArticle]

    var id: String { topic.rawValue }
}

/// Résultat complet d'un `fetchTrending`. `failedTopics` liste les sujets sans AUCUN
/// article récent (flux injoignables, ou flux sans article assez récent) — jamais lancé
/// comme erreur : un échec partiel ne doit jamais faire disparaître les sujets qui ont
/// fonctionné (exigence de la mission 1.8).
nonisolated struct DiscoverContent: Sendable, Equatable {
    let sections: [DiscoverTopicSection]
    let failedTopics: [DiscoverTopic]

    static let empty = DiscoverContent(sections: [], failedTopics: [])
}

/// Un flux à lire pour un sujet.
nonisolated struct DiscoverPlannedFeed: Sendable, Equatable {
    let topic: DiscoverTopic
    let source: FeedSource
}

/// Service Discover : récupère l'actualité de tous les sujets du catalogue à partir de
/// flux RSS/Atom publics, sans backend, sans clé et sans moteur de recherche.
///
/// ## Pourquoi des flux et plus SearXNG (mesure T1, 2026-11-06)
/// Les instances SearXNG publiques refusent après 3 ou 4 requêtes par IP ; un seul
/// chargement de Découvrir en demandait 15, jusqu'à 30. Un flux RSS est fait pour être lu
/// régulièrement, ne coûte qu'une requête, et porte ce qui manquait aux résultats d'un
/// moteur : la DATE de publication réelle. Plus de vieux articles sans date (wikinews,
/// finding Q3 53), plus de pages de rubrique prises pour des articles.
///
/// ## Règles
/// - Au plus `maxConcurrentFeeds` (3) flux en vol : la même politesse qu'avec SearXNG, sujet
///   après sujet, dans l'ordre du catalogue.
/// - Un article sans date, ou plus vieux que `maximumArticleAge`, est écarté.
/// - Plus de mélange aléatoire : le fil est trié du plus récent au plus ancien, donc le même
///   à chaque chargement tant que rien n'est paru. Le mélange faisait changer l'ordre du fil
///   restauré à la fin de chaque actualisation (Q1).
/// - Chaque source garde au plus sa part du sujet (`maxArticlesPerTopic` / nombre de
///   sources, arrondi au-dessus), puis les places libres vont aux plus récents : un flux
///   bavard (The Conversation, 25 articles) ne chasse pas les autres.
/// - Pas de repli SearXNG : ses résultats n'ont pas de date, ils rapporteraient les vieux
///   articles que ce service existe pour écarter, et ils consommeraient le budget de 3 à 4
///   requêtes. Un flux en échec laisse son sujet vide ; l'écran l'explique.
nonisolated struct DiscoverService: Sendable {
    /// Nombre max d'articles conservés par sujet : borne le volume affiché sans pagination.
    static let defaultMaxArticlesPerTopic = 12
    static let defaultMaxConcurrentFeeds = 3
    /// 21 jours : le flux Arts de The Conversation publie quelques articles par semaine, et
    /// une exposition ou un essai ne vieillit pas comme une dépêche. En dessous, ce sujet
    /// resterait vide.
    static let defaultMaximumArticleAge: TimeInterval = 21 * 24 * 3600
    /// Tolérance sur une date « dans le futur » (fuseaux, horloges de serveurs).
    static let futureTolerance: TimeInterval = 24 * 3600

    private let fetcher: any FeedFetching
    private let catalog: [DiscoverTopicDefinition]
    private let maxArticlesPerTopic: Int
    private let maxConcurrentFeeds: Int
    private let maximumArticleAge: TimeInterval
    private let now: @Sendable () -> Date

    init(
        fetcher: any FeedFetching = HTTPFeedFetcher(),
        catalog: [DiscoverTopicDefinition] = DiscoverTopicCatalog.all,
        maxArticlesPerTopic: Int = DiscoverService.defaultMaxArticlesPerTopic,
        maxConcurrentFeeds: Int = DiscoverService.defaultMaxConcurrentFeeds,
        maximumArticleAge: TimeInterval = DiscoverService.defaultMaximumArticleAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.catalog = catalog
        self.maxArticlesPerTopic = max(1, maxArticlesPerTopic)
        self.maxConcurrentFeeds = max(1, maxConcurrentFeeds)
        self.maximumArticleAge = maximumArticleAge
        self.now = now
    }

    /// Flux d'un chargement, dans l'ordre d'envoi : sujet après sujet.
    func plannedFeeds(language: DiscoverLanguage) -> [DiscoverPlannedFeed] {
        catalog.flatMap { definition in
            definition.resolvedSources(for: language).sources.map {
                DiscoverPlannedFeed(topic: definition.topic, source: $0)
            }
        }
    }

    /// Récupère l'actualité de tous les sujets du catalogue.
    /// Rappelable à volonté : le seul état gardé entre deux appels est la mémoire partagée
    /// des requêtes conditionnelles (`FeedRevalidationStore`).
    ///
    /// - Parameters:
    ///   - locale: `Locale.current` n'est PAS une bonne valeur ici : sans localisation
    ///     française dans le projet, elle peut valoir l'anglais sur un appareil réglé
    ///     en français (voir `DiscoverLanguage.device`).
    ///   - onTopicFinished: appelé dès qu'un sujet est terminé, articles vides s'il a
    ///     échoué, pour un affichage progressif.
    func fetchTrending(
        locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? "en"),
        onTopicFinished: DiscoverViewModel.TopicHandler? = nil
    ) async -> DiscoverContent {
        let language = DiscoverLanguage.preferred(for: locale)
        let plan = plannedFeeds(language: language)
        var collector = DiscoverFeedCollector(plan: plan)
        var finished: [DiscoverTopic: [DiscoverArticle]] = [:]
        let finish = { (topic: DiscoverTopic, results: [DiscoverFeedResult]) async in
            let articles = self.articles(for: topic, from: results)
            finished[topic] = articles
            await onTopicFinished?(topic, articles)
        }

        await withTaskGroup(of: (DiscoverTopic, DiscoverFeedResult).self) { group in
            var nextIndex = 0
            var inFlight = 0
            while true {
                while inFlight < maxConcurrentFeeds, nextIndex < plan.count {
                    let feed = plan[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask { (feed.topic, await self.read(feed)) }
                }
                guard let (topic, result) = await group.next() else { break }
                inFlight -= 1
                if let results = collector.record(result, for: topic) {
                    await finish(topic, results)
                }
            }
        }

        // Sujets sans aucun flux prévu : ils sortent en échec, sans attendre personne.
        for definition in catalog where finished[definition.topic] == nil {
            await finish(definition.topic, collector.results(for: definition.topic))
        }

        // Dans l'ordre du catalogue, pas dans celui d'arrivée (voir `DiscoverTopicSection`).
        var sections: [DiscoverTopicSection] = []
        var failedTopics: [DiscoverTopic] = []
        for definition in catalog {
            let articles = finished[definition.topic] ?? []
            if articles.isEmpty {
                failedTopics.append(definition.topic)
            } else {
                sections.append(DiscoverTopicSection(topic: definition.topic, articles: articles))
            }
        }
        return DiscoverContent(sections: sections, failedTopics: failedTopics)
    }

    /// Lit un flux. Ne lève jamais : un flux en échec ne doit pas faire `throw` tout le chargement.
    private func read(_ feed: DiscoverPlannedFeed) async -> DiscoverFeedResult {
        do {
            return DiscoverFeedResult(source: feed.source, items: try await fetcher.items(from: feed.source))
        } catch {
            return DiscoverFeedResult(source: feed.source, items: nil)
        }
    }

    // MARK: Règles pures

    /// Articles d'un sujet : récents et datés, sans doublon, une part par source, du plus
    /// récent au plus ancien.
    func articles(for topic: DiscoverTopic, from results: [DiscoverFeedResult]) -> [DiscoverArticle] {
        let current = now()
        let perSource = results
            .map { recentArticles(topic: topic, result: $0, now: current) }
            .filter { !$0.isEmpty }
        let share = Int((Double(maxArticlesPerTopic) / Double(max(1, perSource.count))).rounded(.up))

        var seen = Set<String>()
        var chosen: [DiscoverArticle] = []
        var rest: [DiscoverArticle] = []
        for list in perSource {
            var taken = 0
            for article in list where seen.insert(article.id).inserted {
                if taken < share {
                    chosen.append(article)
                    taken += 1
                } else {
                    rest.append(article)
                }
            }
        }
        let fill = rest.sorted(by: Self.isNewer).prefix(max(0, maxArticlesPerTopic - chosen.count))
        return Array((chosen + fill).sorted(by: Self.isNewer).prefix(maxArticlesPerTopic))
    }

    /// Les articles datés d'une source, assez récents, du plus récent au plus ancien.
    private func recentArticles(topic: DiscoverTopic, result: DiscoverFeedResult, now: Date) -> [DiscoverArticle] {
        guard let items = result.items else { return [] }
        return items.compactMap { item -> DiscoverArticle? in
            guard let date = item.publishedAt, !item.link.isEmpty,
                  date >= now.addingTimeInterval(-maximumArticleAge),
                  date <= now.addingTimeInterval(Self.futureTolerance)
            else { return nil }
            return DiscoverArticle(topic: topic, item: item, source: result.source)
        }.sorted(by: Self.isNewer)
    }

    /// Plus récent d'abord ; à date égale, l'adresse départage, pour un ordre toujours
    /// identique d'un chargement à l'autre.
    private static func isNewer(_ lhs: DiscoverArticle, _ rhs: DiscoverArticle) -> Bool {
        let left = lhs.publishedAt ?? .distantPast
        let right = rhs.publishedAt ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }
}

/// Ce qu'un flux a rendu : ses articles, ou `nil` s'il n'a pas pu être lu.
nonisolated struct DiscoverFeedResult: Sendable, Equatable {
    let source: FeedSource
    let items: [FeedItem]?
}

/// Suit l'avancement d'un chargement : combien de flux attend encore chaque sujet, et ce
/// que les autres ont rendu.
nonisolated struct DiscoverFeedCollector {
    private var remaining: [DiscoverTopic: Int] = [:]
    private var resultsByTopic: [DiscoverTopic: [DiscoverFeedResult]] = [:]

    init(plan: [DiscoverPlannedFeed]) {
        for feed in plan {
            remaining[feed.topic, default: 0] += 1
        }
    }

    /// Enregistre un résultat. Renvoie tous ceux du sujet quand c'était son dernier flux attendu.
    mutating func record(_ result: DiscoverFeedResult, for topic: DiscoverTopic) -> [DiscoverFeedResult]? {
        resultsByTopic[topic, default: []].append(result)
        let left = (remaining[topic] ?? 1) - 1
        remaining[topic] = left
        return left == 0 ? results(for: topic) : nil
    }

    func results(for topic: DiscoverTopic) -> [DiscoverFeedResult] {
        resultsByTopic[topic] ?? []
    }
}
