//
//  SearXNGModels.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// `nonisolated` : ce sont des porteurs de données purs, déjà `Sendable`, qui
/// traversent en permanence les frontières d'isolation (l'`actor`
/// `FailoverManager`, les providers IA, les vues). Sous
/// `-default-isolation=MainActor`, ils hériteraient sinon de `@MainActor`, ce
/// qui casse deux usages légitimes en mode de langage Swift 6 : une valeur par
/// défaut `SearXNGSearchOptions()` dans une méthode d'`actor` (erreur « main
/// actor-isolated default value in a actor-isolated context », rencontrée sur
/// `FailoverManager.search`), et l'accès à leurs propriétés depuis un contexte
/// non isolé (key paths, `#expect` dans les tests). Même convention que
/// `nonisolated protocol SearXNGSearching: Sendable` dans `SearXNGClient.swift`.
///
/// Paramètres de recherche optionnels transmis à une instance SearXNG.
/// Port direct de `SearxngSearchOptions` (src/lib/searxng.ts).
nonisolated struct SearXNGSearchOptions: Sendable, Equatable {
    var categories: [String] = []
    var engines: [String] = []
    var language: String?
    var pageNumber: Int?
    var timeRange: String?

    init(
        categories: [String] = [],
        engines: [String] = [],
        language: String? = nil,
        pageNumber: Int? = nil,
        timeRange: String? = nil
    ) {
        self.categories = categories
        self.engines = engines
        self.language = language
        self.pageNumber = pageNumber
        self.timeRange = timeRange
    }
}

/// Un résultat de recherche SearXNG. Ne modélise que les champs utilisés
/// côté app — les champs additionnels renvoyés par l'instance (engine,
/// score, positions…) sont ignorés par le décodage, comme côté web.
nonisolated struct SearXNGSearchResult: Codable, Sendable, Equatable, Identifiable {
    var id: String { url }

    let title: String
    let url: String
    let content: String?
    let imgSrc: String?
    let thumbnailSrc: String?
    let thumbnail: String?
    let author: String?
    let iframeSrc: String?

    enum CodingKeys: String, CodingKey {
        case title, url, content, author, thumbnail
        case imgSrc = "img_src"
        case thumbnailSrc = "thumbnail_src"
        case iframeSrc = "iframe_src"
    }
}

/// Réponse complète d'une recherche SearXNG.
nonisolated struct SearXNGSearchResponse: Codable, Sendable, Equatable {
    let results: [SearXNGSearchResult]
    let suggestions: [String]
}
