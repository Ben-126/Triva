//
//  DiscoverFeedCatalog.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Les flux de Découvrir, par sujet et par langue (relevé du 2026-11-11).
///
/// ## Pourquoi si peu de flux
/// Sur une quarantaine de flux publics testés, une dizaine répond correctement, et très
/// peu de leurs éditeurs autorisent la reprise. Ce qui a été écarté, et pourquoi :
/// - réservé à un usage personnel ou non commercial : Le Monde, The Guardian, TechCrunch,
///   Wired, Ars Technica (Condé Nast), The Verge (Vox), NPR, Radio-Canada, BBC, MarketWatch
///   (Dow Jones), The Art Newspaper ;
/// - rediffusion ou collecte automatisée interdite : Beaux Arts, Connaissance des Arts,
///   Télérama, franceinfo, AlloCiné, Hyperallergic ;
/// - conditions muettes ou contradictoires : Maxifoot, ÉcranLarge, France 24, RFI, RTBF ;
/// - flux fermés ou introuvables : Les Échos (403), La Tribune, Capital, Eurosport, Première.
///
/// ## Sport en français
/// Aucun flux français de sport ne remplit la règle d'entrée. Le sujet Sport reprend donc
/// ESPN (en anglais) pour un appareil en français, et la vue le dit (voir
/// `DiscoverTopicDefinition.usesOtherLanguage(than:)`). Décision à valider par Ben.
nonisolated enum DiscoverFeedCatalog {
    private static func url(_ string: String) -> URL {
        // Adresses écrites dans ce fichier : un test (`DiscoverFeedCatalogTests`) vérifie
        // qu'elles sont toutes valides, en https.
        URL(string: string) ?? URL(filePath: "/")
    }

    // MARK: Éditeurs

    /// « Les flux RSS de Numerama peuvent être reproduits librement » (mentions légales).
    private static func numerama(_ id: String, path: String) -> FeedSource {
        FeedSource(
            id: "numerama-\(id)", name: "Numerama",
            url: url("https://www.numerama.com/\(path)feed/"),
            termsURL: url("https://www.numerama.com/mentions-legales/")
        )
    }

    /// « Les flux RSS de Frandroid peuvent être reproduits librement » (mentions légales).
    static let frandroid = FeedSource(
        id: "frandroid", name: "Frandroid",
        url: url("https://www.frandroid.com/feed"),
        termsURL: url("https://www.frandroid.com/mentions-legales")
    )

    /// Licence Creative Commons Attribution / Pas de modification : reprise libre en citant
    /// l'auteur et le site, sans modifier le texte. Seul `summary` est utilisé, pas les images.
    private static func conversation(_ id: String, path: String) -> FeedSource {
        FeedSource(
            id: "conversation-\(id)", name: "The Conversation",
            url: url("https://theconversation.com/\(path)/articles.atom"),
            termsURL: url("https://theconversation.com/fr/republishing-guidelines"),
            usesThumbnails: false
        )
    }

    /// Règles de reprise des flux d'ESPN : afficher uniquement le contenu fourni, lier vers
    /// l'article, indiquer qu'il vient d'ESPN, aucune publicité, aucune modification.
    private static func espn(_ id: String, path: String) -> FeedSource {
        FeedSource(
            id: "espn-\(id)", name: "ESPN",
            url: url("https://www.espn.com/espn/rss/\(path)"),
            termsURL: url("https://www.espn.com/espn/news/story?page=rssinfo")
        )
    }

    /// Penske Media (Variety, Deadline, The Hollywood Reporter, ARTnews), conditions
    /// d'utilisation §19 « Content Feeds » : flux à reprendre tels quels, avec un lien direct
    /// vers l'article complet et la mention du média.
    private static func pmc(_ id: String, name: String, feed: String) -> FeedSource {
        FeedSource(
            id: id, name: name,
            url: url(feed),
            termsURL: url("https://pmc.com/terms-of-use")
        )
    }

    // MARK: Par sujet et par langue

    static func sources(for topic: DiscoverTopic, language: DiscoverLanguage) -> [FeedSource] {
        switch (topic, language) {
        case (.tech, .french):
            [numerama("tech", path: "tech/"), frandroid, conversation("fr-tech", path: "fr/technologie")]
        case (.tech, .english):
            [conversation("us-tech", path: "us/technology")]
        case (.finance, .french):
            [conversation("fr-finance", path: "fr/economie")]
        case (.finance, .english):
            [conversation("us-finance", path: "us/business")]
        case (.art, .french):
            [conversation("fr-art", path: "fr/arts")]
        case (.art, .english):
            [conversation("us-art", path: "us/arts"),
             pmc("artnews", name: "ARTnews", feed: "https://www.artnews.com/feed/")]
        case (.sports, .french):
            []
        case (.sports, .english):
            [espn("news", path: "news"), espn("soccer", path: "soccer/news")]
        case (.entertainment, .french):
            [numerama("pop-culture", path: "pop-culture/")]
        case (.entertainment, .english):
            [pmc("variety", name: "Variety", feed: "https://variety.com/feed/"),
             pmc("deadline", name: "Deadline", feed: "https://deadline.com/feed/"),
             pmc("thr", name: "The Hollywood Reporter", feed: "https://www.hollywoodreporter.com/feed/")]
        }
    }

    /// Tous les flux, pour les tests et le rapport légal.
    static var allSources: [FeedSource] {
        DiscoverTopic.allCases.flatMap { topic in
            DiscoverLanguage.allCases.flatMap { sources(for: topic, language: $0) }
        }
    }

    /// Sources utilisées pour `topic` sur un appareil dans `language`. Quand la langue n'a
    /// aucun flux pour ce sujet, l'autre langue prend le relais : un sujet affiché vaut mieux
    /// qu'une puce vide, et la vue signale la langue (`isFallback`).
    static func resolvedSources(
        for topic: DiscoverTopic,
        language: DiscoverLanguage
    ) -> (sources: [FeedSource], isFallback: Bool) {
        let own = sources(for: topic, language: language)
        if !own.isEmpty { return (own, false) }
        let otherLanguage = DiscoverLanguage.allCases.first { $0 != language } ?? language
        return (sources(for: topic, language: otherLanguage), true)
    }
}
