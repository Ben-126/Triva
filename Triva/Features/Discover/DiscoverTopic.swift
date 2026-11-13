//
//  DiscoverTopic.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Les 5 sujets de contenu tendance, identiques à `websitesForTopic`
/// de la version web d'origine — la liste de sujets elle-même n'est
/// pas une décision produit à reprendre, seule sa source de données change (des flux
/// RSS/Atom, plus des recherches SearXNG).
nonisolated enum DiscoverTopic: String, CaseIterable, Sendable, Equatable, Hashable, Codable {
    case tech
    case finance
    case art
    case sports
    case entertainment
}

/// Langue de contenu Discover : FR ou EN uniquement (décision de Ben, voir
/// mission 1.8 — pas de couverture multilingue complète, deux jeux de flux par sujet
/// suffisent).
nonisolated enum DiscoverLanguage: String, Sendable, CaseIterable, Equatable {
    case french = "fr"
    case english = "en"

    /// Sélectionne la langue de contenu à partir de la locale système —
    /// FR si l'appareil est réglé en français, EN dans tous les autres cas
    /// (repli documenté par Ben plutôt qu'une vraie couverture multilingue).
    static func preferred(for locale: Locale) -> DiscoverLanguage {
        locale.language.languageCode?.identifier == Locale.LanguageCode.french.identifier
            ? .french
            : .english
    }

    /// Langue de contenu de l'appareil. `Locale.preferredLanguages`, jamais
    /// `Locale.current` : sans localisation française dans le projet, cette
    /// dernière peut valoir l'anglais sur un appareil réglé en français (voir
    /// `AnswerExcerpt.swift`).
    static func device(preferredLanguages: [String] = Locale.preferredLanguages) -> DiscoverLanguage {
        preferred(for: Locale(identifier: preferredLanguages.first ?? "en"))
    }
}

/// Un sujet complet du catalogue Discover : libellé + SF Symbol pour l'UI. Les flux qui
/// l'alimentent, par langue, sont dans `DiscoverFeedCatalog` (avec ce qui justifie chacun).
nonisolated struct DiscoverTopicDefinition: Sendable, Equatable, Identifiable {
    let topic: DiscoverTopic
    let title: String
    let systemImage: String

    var id: String { topic.rawValue }

    /// Flux de ce sujet pour `language`, avec repli sur l'autre langue si la première n'en
    /// a aucun (voir `DiscoverFeedCatalog.resolvedSources`).
    func resolvedSources(for language: DiscoverLanguage) -> (sources: [FeedSource], isFallback: Bool) {
        DiscoverFeedCatalog.resolvedSources(for: topic, language: language)
    }

    /// Vrai si les articles de ce sujet ne sont pas dans la langue de l'appareil, faute de
    /// flux utilisable dans celle-ci : la vue le dit plutôt que de laisser croire à un défaut.
    func usesOtherLanguage(than language: DiscoverLanguage) -> Bool {
        resolvedSources(for: language).isFallback
    }
}

/// Catalogue statique des 5 sujets Discover (les flux sont dans `DiscoverFeedCatalog`).
nonisolated enum DiscoverTopicCatalog {
    static let all: [DiscoverTopicDefinition] = [
        DiscoverTopicDefinition(topic: .tech, title: "Tech", systemImage: "cpu"),
        DiscoverTopicDefinition(topic: .finance, title: "Finance", systemImage: "chart.line.uptrend.xyaxis"),
        DiscoverTopicDefinition(topic: .art, title: "Art & Culture", systemImage: "paintpalette"),
        DiscoverTopicDefinition(topic: .sports, title: "Sport", systemImage: "sportscourt"),
        DiscoverTopicDefinition(topic: .entertainment, title: "Divertissement", systemImage: "film"),
    ]
}
