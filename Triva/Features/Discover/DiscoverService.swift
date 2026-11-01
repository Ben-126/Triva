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

/// Service Discover (1.8) : récupère le contenu tendance de tous les sujets
/// du catalogue en une fois, groupé par sujet, sans backend — chaque requête
/// part directement vers les instances SearXNG publiques via
/// `FailoverManager` (même dépendance que `SearchOrchestrator`).
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
struct DiscoverService: Sendable {
    /// Nombre max d'articles conservés par sujet après mélange — borne le
    /// volume affiché (un sujet a jusqu'à `domaines * requêtes` résultats
    /// bruts possibles, largement plus que ce qu'une UI doit montrer) sans
    /// dépendre d'une pagination.
    static let defaultMaxArticlesPerTopic = 12

    private let failoverManager: FailoverManager
    private let shuffler: any DiscoverArticleShuffling
    private let catalog: [DiscoverTopicDefinition]
    private let maxArticlesPerTopic: Int

    init(
        failoverManager: FailoverManager,
        shuffler: any DiscoverArticleShuffling = SystemDiscoverArticleShuffler(),
        catalog: [DiscoverTopicDefinition] = DiscoverTopicCatalog.all,
        maxArticlesPerTopic: Int = DiscoverService.defaultMaxArticlesPerTopic
    ) {
        self.failoverManager = failoverManager
        self.shuffler = shuffler
        self.catalog = catalog
        self.maxArticlesPerTopic = maxArticlesPerTopic
    }

    /// Récupère le contenu tendance de tous les sujets du catalogue.
    /// Rappelable à volonté (aucun état interne conservé entre deux appels)
    /// pour couvrir le rafraîchissement demandé par la mission 1.8 — chaque
    /// appel relance toutes les recherches et remélange les résultats.
    func fetchTrending(locale: Locale = .current) async -> DiscoverContent {
        let language = DiscoverLanguage.preferred(for: locale)

        // TaskGroup au niveau SUJET : chaque sujet est indépendant, un sujet
        // lent ou totalement en échec ne doit ni retarder ni faire échouer
        // les autres (exigence explicite de la mission).
        let resultsByTopic = await withTaskGroup(
            of: (DiscoverTopic, [DiscoverArticle]).self,
            returning: [DiscoverTopic: [DiscoverArticle]].self
        ) { group in
            for definition in catalog {
                group.addTask {
                    (definition.topic, await self.fetchArticles(for: definition, language: language))
                }
            }
            var collected: [DiscoverTopic: [DiscoverArticle]] = [:]
            for await (topic, articles) in group {
                collected[topic] = articles
            }
            return collected
        }

        // Remis dans l'ordre du catalogue : un `TaskGroup` complète ses
        // tâches dans l'ordre de fin, pas de lancement (voir doc de
        // `DiscoverTopicSection`).
        var sections: [DiscoverTopicSection] = []
        var failedTopics: [DiscoverTopic] = []
        for definition in catalog {
            let articles = resultsByTopic[definition.topic] ?? []
            if articles.isEmpty {
                failedTopics.append(definition.topic)
            } else {
                sections.append(DiscoverTopicSection(topic: definition.topic, articles: articles))
            }
        }

        return DiscoverContent(sections: sections, failedTopics: failedTopics)
    }

    /// Recherche toutes les combinaisons domaine x requête d'UN sujet en
    /// parallèle, dédoublonne, mélange, borne. Ne throw jamais : chaque
    /// combinaison individuelle avale ses propres erreurs
    /// (`searchOneCombo`), donc au pire cette fonction renvoie `[]`.
    private func fetchArticles(
        for definition: DiscoverTopicDefinition,
        language: DiscoverLanguage
    ) async -> [DiscoverArticle] {
        let content = definition.localizedContent(for: language)
        guard !content.domains.isEmpty, !content.queries.isEmpty else {
            return []
        }

        let allResults = await withTaskGroup(
            of: [SearXNGSearchResult].self,
            returning: [[SearXNGSearchResult]].self
        ) { group in
            for domain in content.domains {
                for query in content.queries {
                    group.addTask {
                        await self.searchOneCombo(domain: domain, query: query, language: language)
                    }
                }
            }
            var collected: [[SearXNGSearchResult]] = []
            for await results in group {
                collected.append(results)
            }
            return collected
        }

        var seenKeys = Set<String>()
        var articles: [DiscoverArticle] = []
        for results in allResults {
            for result in results {
                let key = DiscoverArticle.normalizedKey(for: result.url)
                guard !key.isEmpty, !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)
                articles.append(DiscoverArticle(topic: definition.topic, result: result))
            }
        }

        return Array(shuffler.shuffled(articles).prefix(maxArticlesPerTopic))
    }

    /// Une combinaison `site:domaine requête` : tente d'abord la catégorie
    /// `news`, retente sans restriction si ça ne renvoie rien (voir la
    /// divergence documentée en tête de fichier). N'importe quelle erreur
    /// réseau (toutes les instances indisponibles, timeout...) est avalée en
    /// `[]` — c'est le contrat attendu par `fetchArticles`/`fetchTrending` :
    /// un sujet entier ne doit jamais faire `throw`.
    private func searchOneCombo(
        domain: String,
        query: String,
        language: DiscoverLanguage
    ) async -> [SearXNGSearchResult] {
        let searchQuery = "site:\(domain) \(query)"

        let newsOptions = SearXNGSearchOptions(
            categories: ["news"],
            language: language.rawValue,
            pageNumber: 1
        )
        if let response = try? await failoverManager.search(query: searchQuery, options: newsOptions),
           !response.results.isEmpty {
            return response.results
        }

        let unrestrictedOptions = SearXNGSearchOptions(language: language.rawValue, pageNumber: 1)
        guard let fallbackResponse = try? await failoverManager.search(query: searchQuery, options: unrestrictedOptions) else {
            return []
        }
        return fallbackResponse.results
    }
}
