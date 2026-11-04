//
//  DiscoverTopic.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Les 5 sujets de contenu tendance, identiques à `websitesForTopic`
/// (src/app/api/discover/route.ts, web) — la liste de sujets elle-même n'est
/// pas une décision produit à reprendre, seule sa source de données change.
enum DiscoverTopic: String, CaseIterable, Sendable, Equatable, Hashable, Codable {
    case tech
    case finance
    case art
    case sports
    case entertainment
}

/// Langue de contenu Discover : FR ou EN uniquement (décision de Ben, voir
/// mission 1.8 — pas de couverture multilingue complète, deux jeux de
/// requêtes/domaines par sujet suffisent).
enum DiscoverLanguage: String, Sendable, CaseIterable, Equatable {
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

/// Requêtes + domaines sources pour un sujet, dans UNE langue. Port de
/// `websitesForTopic[topic].query` / `.links` (web), mais dédoublé par
/// langue : le web ne connaît que l'anglais (`language: 'en'` en dur dans
/// `searchSearxng`).
struct DiscoverLocalizedTopicContent: Sendable, Equatable {
    let queries: [String]
    let domains: [String]
}

/// Un sujet complet du catalogue Discover : libellé + SF Symbol pour l'UI
/// (1.8 vue, hors périmètre de ce fichier) et son contenu dans chaque langue
/// supportée.
struct DiscoverTopicDefinition: Sendable, Equatable, Identifiable {
    let topic: DiscoverTopic
    let title: String
    let systemImage: String
    private let localizedContentByLanguage: [DiscoverLanguage: DiscoverLocalizedTopicContent]

    var id: String { topic.rawValue }

    init(
        topic: DiscoverTopic,
        title: String,
        systemImage: String,
        localizedContentByLanguage: [DiscoverLanguage: DiscoverLocalizedTopicContent]
    ) {
        self.topic = topic
        self.title = title
        self.systemImage = systemImage
        self.localizedContentByLanguage = localizedContentByLanguage
    }

    /// Contenu pour `language`, avec repli sur l'anglais si la langue
    /// demandée n'a pas d'entrée dans le catalogue (ne devrait jamais
    /// arriver vu `DiscoverTopicCatalog.all`, mais évite un crash si le
    /// catalogue est un jour modifié sans mettre à jour toutes les langues).
    func localizedContent(for language: DiscoverLanguage) -> DiscoverLocalizedTopicContent {
        localizedContentByLanguage[language]
            ?? localizedContentByLanguage[.english]
            ?? DiscoverLocalizedTopicContent(queries: [], domains: [])
    }
}

/// Catalogue statique des 5 sujets Discover. Domaines EN repris tels quels
/// de `websitesForTopic` (web) ; domaines FR ajoutés par choix éditorial
/// (décision de Ben : "locale système, sources FR et EN") — sites
/// francophones reconnus et actifs de longue date par sujet, pas une liste
/// exhaustive.
enum DiscoverTopicCatalog {
    static let all: [DiscoverTopicDefinition] = [
        DiscoverTopicDefinition(
            topic: .tech,
            title: "Tech",
            systemImage: "cpu",
            localizedContentByLanguage: [
                .english: DiscoverLocalizedTopicContent(
                    queries: ["technology news", "latest tech", "AI", "science and innovation"],
                    domains: ["techcrunch.com", "wired.com", "theverge.com"]
                ),
                .french: DiscoverLocalizedTopicContent(
                    queries: ["actualité technologique", "intelligence artificielle", "innovation"],
                    domains: ["lemonde.fr/pixels", "numerama.com", "next.ink"]
                ),
            ]
        ),
        DiscoverTopicDefinition(
            topic: .finance,
            title: "Finance",
            systemImage: "chart.line.uptrend.xyaxis",
            localizedContentByLanguage: [
                .english: DiscoverLocalizedTopicContent(
                    queries: ["finance news", "economy", "stock market", "investing"],
                    domains: ["bloomberg.com", "cnbc.com", "marketwatch.com"]
                ),
                .french: DiscoverLocalizedTopicContent(
                    queries: ["actualité économique", "bourse", "marchés financiers"],
                    domains: ["lesechos.fr", "latribune.fr", "capital.fr"]
                ),
            ]
        ),
        DiscoverTopicDefinition(
            topic: .art,
            title: "Art & Culture",
            systemImage: "paintpalette",
            localizedContentByLanguage: [
                .english: DiscoverLocalizedTopicContent(
                    queries: ["art news", "culture", "modern art", "cultural events"],
                    domains: ["artnews.com", "hyperallergic.com", "theartnewspaper.com"]
                ),
                .french: DiscoverLocalizedTopicContent(
                    queries: ["actualité culturelle", "exposition art", "musée"],
                    domains: ["connaissancedesarts.com", "beauxarts.com", "telerama.fr"]
                ),
            ]
        ),
        DiscoverTopicDefinition(
            topic: .sports,
            title: "Sport",
            systemImage: "sportscourt",
            localizedContentByLanguage: [
                .english: DiscoverLocalizedTopicContent(
                    queries: ["sports news", "latest sports", "football tennis"],
                    domains: ["espn.com", "bbc.com/sport", "skysports.com"]
                ),
                .french: DiscoverLocalizedTopicContent(
                    queries: ["actualité sportive", "football", "résultats sport"],
                    domains: ["lequipe.fr", "rmcsport.bfmtv.com", "eurosport.fr"]
                ),
            ]
        ),
        DiscoverTopicDefinition(
            topic: .entertainment,
            title: "Divertissement",
            systemImage: "film",
            localizedContentByLanguage: [
                .english: DiscoverLocalizedTopicContent(
                    queries: ["entertainment news", "movies", "TV shows", "celebrities"],
                    domains: ["hollywoodreporter.com", "variety.com", "deadline.com"]
                ),
                .french: DiscoverLocalizedTopicContent(
                    queries: ["actualité cinéma", "séries télé", "sorties films"],
                    domains: ["allocine.fr", "premiere.fr", "ecranlarge.com"]
                ),
            ]
        ),
    ]
}
