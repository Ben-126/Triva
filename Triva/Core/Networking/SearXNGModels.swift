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
/// Port direct de `SearxngSearchOptions` de la version web d'origine.
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
/// score, positions…) sont ignorés par le décodage, comme dans la version web d'origine.
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

    /// `true` quand l'extrait (`content`) vient d'un fournisseur dont les conditions interdisent de
    /// le conserver au-delà de la réponse en cours (Brave Search API : décision Q6, 2026-11-14).
    /// L'extrait reste utilisable pendant la réponse (prompt, classement) ; l'historique et les
    /// favoris n'en gardent que le titre et le lien (voir `persistedExcerpt`). Hors de `CodingKeys`
    /// : jamais encodé ni décodé, `false` par défaut. À FAIRE VALIDER par un juriste (audit n° 22).
    var excerptIsTransient: Bool = false

    /// Extrait autorisé à être écrit sur le disque (historique, favoris) : `nil` si transitoire.
    var persistedExcerpt: String? { excerptIsTransient ? nil : content }

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
    /// Moteurs qui n'ont pas répondu (bloqués, suspendus, en délai dépassé).
    /// SearXNG renvoie alors un HTTP 200 avec `results` vide : ce champ dit
    /// pourquoi (bug 5, diagnostic). `nil` si absent ou de forme inattendue —
    /// il ne doit jamais faire échouer le décodage de toute la réponse.
    let unresponsiveEngines: [String]?

    init(results: [SearXNGSearchResult], suggestions: [String], unresponsiveEngines: [String]? = nil) {
        self.results = results
        self.suggestions = suggestions
        self.unresponsiveEngines = unresponsiveEngines
    }

    enum CodingKeys: String, CodingKey {
        case results, suggestions
        case unresponsiveEngines = "unresponsive_engines"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([SearXNGSearchResult].self, forKey: .results)
        suggestions = try container.decode([String].self, forKey: .suggestions)
        // Forme réelle : une liste de paires [moteur, motif].
        let pairs = try? container.decodeIfPresent([[String]].self, forKey: .unresponsiveEngines)
        unresponsiveEngines = pairs?.compactMap(\.first)
    }
}
