//
//  DiscoverService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Un article tendance, prêt pour l'affichage — dérivé d'un
/// `SearXNGSearchResult` mais recadré sur ce dont Discover a besoin
/// (`imageURL` déjà parsée, `id` déjà normalisé pour servir de clé
/// `Identifiable` ET de clé de déduplication).
struct DiscoverArticle: Sendable, Equatable, Identifiable {
    let id: String
    let topic: DiscoverTopic
    let title: String
    let url: String
    let snippet: String?
    let imageURL: URL?

    init(topic: DiscoverTopic, result: SearXNGSearchResult) {
        self.topic = topic
        self.title = result.title
        self.url = result.url
        self.snippet = result.content
        self.imageURL = (result.imgSrc ?? result.thumbnail ?? result.thumbnailSrc)
            .flatMap { URL(string: $0) }
        self.id = Self.normalizedKey(for: result.url)
    }

    /// Article restauré du cache (`DiscoverCacheSnapshot.restored()`).
    init(topic: DiscoverTopic, title: String, url: String, snippet: String?, imageURL: URL?) {
        self.topic = topic
        self.title = title
        self.url = url
        self.snippet = snippet
        self.imageURL = imageURL
        self.id = Self.normalizedKey(for: url)
    }

    /// Même règle de déduplication que le web (`item.url?.toLowerCase().trim()`,
    /// route.ts) : suffisant pour éliminer les doublons exacts entre domaines/
    /// requêtes qui remontent la même URL, pas une normalisation d'URL
    /// complète (paramètres de tracking, www., etc.) — non nécessaire ici,
    /// le volume par sujet est petit et borné par `maxArticlesPerTopic`.
    static func normalizedKey(for url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Les articles collectés pour un sujet, dans l'ordre du catalogue
/// (`DiscoverContent.sections`), pas dans l'ordre d'arrivée réseau — un
/// `TaskGroup` complète ses tâches dans un ordre non déterministe, et une UI
/// dont les sections sautent de place à chaque rafraîchissement serait
/// désorientante.
struct DiscoverTopicSection: Sendable, Equatable, Identifiable {
    let topic: DiscoverTopic
    let articles: [DiscoverArticle]

    var id: String { topic.rawValue }
}

/// Résultat complet d'un `fetchTrending`. `failedTopics` liste les sujets
/// pour lesquels AUCUNE combinaison domaine/requête n'a renvoyé de résultat
/// (erreur réseau totale ou instance SearXNG qui ne connaît aucun des
/// domaines demandés) — jamais lancé comme erreur : un échec partiel ne doit
/// jamais faire disparaître les sujets qui ont fonctionné (exigence de la
/// mission 1.8).
struct DiscoverContent: Sendable, Equatable {
    let sections: [DiscoverTopicSection]
    let failedTopics: [DiscoverTopic]

    static let empty = DiscoverContent(sections: [], failedTopics: [])
}

/// Abstraction du mélange aléatoire des articles avant bornage — remplace
/// `Math.random()` (route.ts, `.sort(() => Math.random() - 0.5)`), qui n'a
/// pas d'équivalent testable de façon déterministe. Même principe DI que
/// `SearXNGSearching`/`ScrapeServing` : un protocole + une implémentation
/// système par défaut, un mock déterministe (typiquement l'identité) dans
/// les tests.
nonisolated protocol DiscoverArticleShuffling: Sendable {
    func shuffled(_ articles: [DiscoverArticle]) -> [DiscoverArticle]
}

/// Implémentation de production : `Array.shuffled()` (générateur système,
/// non déterministe par construction — c'est le but, éviter que le même
/// article soit toujours en tête à chaque rafraîchissement).
struct SystemDiscoverArticleShuffler: DiscoverArticleShuffling {
    init() {}

    func shuffled(_ articles: [DiscoverArticle]) -> [DiscoverArticle] {
        articles.shuffled()
    }
}

/// Une recherche prévue par `DiscoverService` : un sujet, un domaine, une requête.
struct DiscoverPlannedSearch: Sendable, Equatable {
    let topic: DiscoverTopic
    let domain: String
    let query: String
}

/// Service Discover (1.8) : récupère le contenu tendance de tous les sujets
/// du catalogue, groupé par sujet, sans backend — chaque requête part directement
/// vers les instances SearXNG publiques via `FailoverManager` (même dépendance que
/// `SearchOrchestrator`).
///
/// DIVERGENCE assumée vis-à-vis du web : `route.ts` répond à UN `topic` à la
/// fois (paramètre de requête HTTP, page qui affiche un sujet sélectionné).
/// Ben a validé un modèle différent pour l'app : tous les sujets sont
/// récupérés ensemble et regroupés, pour une vue Discover qui montre
/// plusieurs sections en une fois plutôt qu'un sélecteur de sujet + rechargement.
///
/// DIVERGENCE assumée #2 : le web force `engines: ['bing news']`. Une
/// instance SearXNG publique n'active pas forcément ce moteur précis (elles
/// sont configurées indépendamment par leurs opérateurs, contrairement au
/// serveur du web qui contrôle sa propre instance) — un moteur absent en
/// SearXNG ne fait pas échouer la recherche, il l'ignore silencieusement et
/// renvoie 0 résultat. On utilise donc la catégorie `news` (supportée par
/// la quasi-totalité des instances) plutôt qu'un moteur nommé, et on retente
/// sans aucune restriction si la catégorie ne renvoie rien (`searchOneCombo`)
/// — un sujet ne doit pas rester vide juste parce que l'instance du moment
/// classe mal ses actualités.
///
/// ## Pas de rafale (mesuré sur le vrai réseau le 2026-11-04)
/// Le croisement complet domaines × requêtes lançait environ 50 recherches
/// simultanées. Toutes choisissaient leur instance AVANT qu'aucune n'ait répondu :
/// ni le cache de dernière instance de `FailoverManager` ni sa mise de côté ne
/// servaient pendant le chargement. Sur la liste publique : 456 requêtes, 18 s, et
/// aucun article. D'où trois règles :
/// - `combosPerTopic` recherches par sujet (15 au total), qui varient d'une fois à
///   l'autre (`searches(for:rotation:)`) ;
/// - au plus `maxConcurrentSearches` en vol, sujet après sujet : la première vague
///   apprend au manager quelle instance répond, et les sujets arrivent dans l'ordre
///   du catalogue ;
/// - quand assez de recherches ont épuisé toutes les instances sans aucun succès,
///   les suivantes ne partent pas : elles échoueraient pareil.
struct DiscoverService: Sendable {
    /// Nombre max d'articles conservés par sujet après mélange — borne le
    /// volume affiché sans dépendre d'une pagination.
    static let defaultMaxArticlesPerTopic = 12
    /// Une recherche par domaine du catalogue : 15 pour les 5 sujets.
    static let combosPerTopic = 3
    static let defaultMaxConcurrentSearches = 3
    /// Recherches qui épuisent toutes les instances, sans aucune réponse, avant de
    /// renoncer aux suivantes. Plus d'une : avec une liste d'une seule instance, un
    /// refus passager ne doit pas priver tous les sujets.
    static let failedSearchesBeforeStopping = 3

    private let failoverManager: FailoverManager
    private let shuffler: any DiscoverArticleShuffling
    private let catalog: [DiscoverTopicDefinition]
    private let maxArticlesPerTopic: Int
    private let maxConcurrentSearches: Int
    private let queryRotation: @Sendable () -> Int

    /// - Parameter queryRotation: décale les requêtes associées aux domaines, pour
    ///   couvrir tout le catalogue au fil des chargements ; aléatoire par défaut.
    init(
        failoverManager: FailoverManager,
        shuffler: any DiscoverArticleShuffling = SystemDiscoverArticleShuffler(),
        catalog: [DiscoverTopicDefinition] = DiscoverTopicCatalog.all,
        maxArticlesPerTopic: Int = DiscoverService.defaultMaxArticlesPerTopic,
        maxConcurrentSearches: Int = DiscoverService.defaultMaxConcurrentSearches,
        queryRotation: @escaping @Sendable () -> Int = { Int.random(in: 0..<1_000) }
    ) {
        self.failoverManager = failoverManager
        self.shuffler = shuffler
        self.catalog = catalog
        self.maxArticlesPerTopic = maxArticlesPerTopic
        self.maxConcurrentSearches = max(1, maxConcurrentSearches)
        self.queryRotation = queryRotation
    }

    /// Recherches d'un chargement, dans l'ordre d'envoi : sujet après sujet.
    func plannedSearches(language: DiscoverLanguage) -> [DiscoverPlannedSearch] {
        let rotation = queryRotation()
        return catalog.flatMap { definition in
            Self.searches(for: definition.localizedContent(for: language), rotation: rotation).map {
                DiscoverPlannedSearch(topic: definition.topic, domain: $0.domain, query: $0.query)
            }
        }
    }

    /// Les `combosPerTopic` couples domaine × requête d'un sujet : en parcourant les
    /// diagonales du croisement, chaque domaine sert une fois avant qu'un domaine ne
    /// serve deux fois, et avec une requête différente tant qu'il y en a assez.
    static func searches(
        for content: DiscoverLocalizedTopicContent,
        rotation: Int
    ) -> [(domain: String, query: String)] {
        guard !content.domains.isEmpty, !content.queries.isEmpty else { return [] }
        let queryCount = content.queries.count
        let all = (0..<queryCount).flatMap { shift in
            content.domains.enumerated().map { index, domain in
                (domain: domain, query: content.queries[(rotation + index + shift) % queryCount])
            }
        }
        return Array(all.prefix(combosPerTopic))
    }

    /// Récupère le contenu tendance de tous les sujets du catalogue.
    /// Rappelable à volonté (aucun état interne conservé entre deux appels)
    /// pour couvrir le rafraîchissement demandé par la mission 1.8 — chaque
    /// appel relance les recherches et remélange les résultats.
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
        let plan = plannedSearches(language: language)
        var collector = DiscoverSearchCollector(plan: plan)
        var finished: [DiscoverTopic: [DiscoverArticle]] = [:]
        let finish = { (topic: DiscoverTopic, results: [SearXNGSearchResult]) in
            let articles = self.articles(for: topic, from: results)
            finished[topic] = articles
            onTopicFinished?(topic, articles)
        }

        await withTaskGroup(of: (DiscoverTopic, DiscoverSearchOutcome).self) { group in
            var nextIndex = 0
            var inFlight = 0
            while true {
                while inFlight < maxConcurrentSearches,
                      nextIndex < plan.count,
                      !collector.shouldStop(threshold: Self.failedSearchesBeforeStopping) {
                    let search = plan[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        (search.topic, await self.searchOneCombo(search, language: language))
                    }
                }
                guard let (topic, outcome) = await group.next() else { break }
                inFlight -= 1
                if let results = collector.record(outcome, for: topic) {
                    finish(topic, results)
                }
            }
        }

        // Sujets sans recherche prévue, ou arrêtés avant la fin : ce qu'ils ont.
        for definition in catalog where finished[definition.topic] == nil {
            finish(definition.topic, collector.results(for: definition.topic))
        }

        // Dans l'ordre du catalogue, pas dans celui d'arrivée (voir la doc de
        // `DiscoverTopicSection`).
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

    /// Dédoublonne, mélange, borne.
    private func articles(for topic: DiscoverTopic, from results: [SearXNGSearchResult]) -> [DiscoverArticle] {
        var seenKeys = Set<String>()
        var articles: [DiscoverArticle] = []
        for result in results {
            let key = DiscoverArticle.normalizedKey(for: result.url)
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            articles.append(DiscoverArticle(topic: topic, result: result))
        }
        return Array(shuffler.shuffled(articles).prefix(maxArticlesPerTopic))
    }

    /// Une combinaison `site:domaine requête` : tente d'abord la catégorie `news`, et
    /// retente sans restriction si elle ne renvoie RIEN (voir la divergence documentée
    /// en tête de fichier). Une ERREUR ne se retente pas : toutes les instances
    /// viennent d'échouer, les reparcourir pour la même requête n'apporterait rien.
    /// Ne lève jamais : un sujet entier ne doit jamais faire `throw`.
    private func searchOneCombo(
        _ search: DiscoverPlannedSearch,
        language: DiscoverLanguage
    ) async -> DiscoverSearchOutcome {
        let searchQuery = "site:\(search.domain) \(search.query)"
        do {
            let newsOptions = SearXNGSearchOptions(
                categories: ["news"],
                language: language.rawValue,
                pageNumber: 1
            )
            let news = try await failoverManager.search(query: searchQuery, options: newsOptions)
            guard news.results.isEmpty else { return .answered(news.results) }

            let unrestrictedOptions = SearXNGSearchOptions(language: language.rawValue, pageNumber: 1)
            let unrestricted = try await failoverManager.search(query: searchQuery, options: unrestrictedOptions)
            return .answered(unrestricted.results)
        } catch {
            return .failed
        }
    }
}

/// Issue d'une recherche : une instance a répondu (éventuellement sans résultat), ou
/// aucune instance n'a répondu.
enum DiscoverSearchOutcome: Sendable {
    case answered([SearXNGSearchResult])
    case failed
}

/// Suit l'avancement d'un chargement : ce qui reste à recevoir par sujet, les
/// résultats reçus, et s'il vaut encore la peine d'envoyer des recherches.
struct DiscoverSearchCollector {
    private var remaining: [DiscoverTopic: Int] = [:]
    private var resultsByTopic: [DiscoverTopic: [SearXNGSearchResult]] = [:]
    private var answeredCount = 0
    private var failedCount = 0

    init(plan: [DiscoverPlannedSearch]) {
        for search in plan {
            remaining[search.topic, default: 0] += 1
        }
    }

    /// Enregistre une issue. Renvoie les résultats du sujet quand c'était sa dernière
    /// recherche attendue.
    mutating func record(_ outcome: DiscoverSearchOutcome, for topic: DiscoverTopic) -> [SearXNGSearchResult]? {
        switch outcome {
        case .answered(let results):
            answeredCount += 1
            resultsByTopic[topic, default: []].append(contentsOf: results)
        case .failed:
            failedCount += 1
        }
        let left = (remaining[topic] ?? 1) - 1
        remaining[topic] = left
        return left == 0 ? results(for: topic) : nil
    }

    func results(for topic: DiscoverTopic) -> [SearXNGSearchResult] {
        resultsByTopic[topic] ?? []
    }

    /// Vrai si `threshold` recherches ont épuisé toutes les instances sans qu'aucune
    /// n'ait reçu de réponse : hors ligne ou liste entièrement refusée, les suivantes
    /// échoueraient pareil.
    func shouldStop(threshold: Int) -> Bool {
        answeredCount == 0 && failedCount >= threshold
    }
}
