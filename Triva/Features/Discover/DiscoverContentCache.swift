//
//  DiscoverContentCache.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import OSLog

/// Ce qui est conservé des articles de la dernière visite de Découvrir, pour les
/// afficher tout de suite au lancement suivant. Sujets et adresses en `String` :
/// ce format `nonisolated` se décode hors du main actor, et un sujet inconnu
/// (retour à une version antérieure de l'app) est écarté à la restauration au lieu
/// de faire échouer tout le fichier.
nonisolated struct DiscoverCacheSnapshot: Codable, Sendable, Equatable {
    /// À incrémenter si le format change : un fichier d'une autre version est
    /// ignoré, puis remplacé à la prochaine mise à jour réussie.
    /// Version 2 (flux RSS) : date de publication et nom de la source. Les fichiers de la
    /// version 1 venaient de recherches SearXNG (extraits abîmés, vieux articles sans date) :
    /// on ne veut pas les réafficher.
    static let currentVersion = 2

    struct Article: Codable, Sendable, Equatable {
        let title: String
        let url: String
        let snippet: String?
        let imageURL: String?
        let publishedAt: Date?
        let sourceName: String?
    }

    struct Section: Codable, Sendable, Equatable {
        let topic: String
        let fetchedAt: Date
        let articles: [Article]
    }

    let version: Int
    let sections: [Section]

    init(version: Int = DiscoverCacheSnapshot.currentVersion, sections: [Section]) {
        self.version = version
        self.sections = sections
    }
}

/// Sauvegarde des articles. Ne lève jamais : un cache absent, abîmé ou impossible
/// à écrire ne doit ni bloquer ni faire planter l'écran, qui repart alors du réseau.
nonisolated protocol DiscoverContentCaching: Sendable {
    func load() async -> DiscoverCacheSnapshot?
    func save(_ snapshot: DiscoverCacheSnapshot) async
    /// Supprime ce qui est en cache (action « Tout effacer » des Réglages).
    func clear() async
}

extension DiscoverContentCaching {
    /// Par défaut, rien à supprimer : seul un cache sur disque a quelque chose à effacer.
    func clear() async {}
}

/// Aucun cache : défaut des tests et des aperçus, qui ne touchent pas au disque.
nonisolated struct DiscoverNoCache: DiscoverContentCaching {
    func load() async -> DiscoverCacheSnapshot? { nil }
    func save(_ snapshot: DiscoverCacheSnapshot) async {}
}

/// Cache sur disque : un fichier JSON par langue dans `Caches`, le dossier que le
/// système peut vider et que les sauvegardes ignorent. Ces articles publics se
/// retrouvent sur le réseau et ne révèlent rien sur l'utilisateur. `@concurrent` :
/// lecture et décodage quittent le main actor.
nonisolated struct DiscoverDiskCache: DiscoverContentCaching {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "DiscoverDiskCache"
    )

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Fichier réservé à `language` : des articles dans une autre langue que celle
    /// de l'appareil ne s'afficheront pas après un changement de réglage.
    init(language: DiscoverLanguage) {
        self.init(fileURL: URL.cachesDirectory.appending(path: "discover-\(language.rawValue).json"))
    }

    @concurrent
    func load() async -> DiscoverCacheSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Self.logger.error("Lecture impossible : \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            let snapshot = try JSONDecoder().decode(DiscoverCacheSnapshot.self, from: data)
            return snapshot.version == DiscoverCacheSnapshot.currentVersion ? snapshot : nil
        } catch {
            Self.logger.error("Cache illisible, ignoré : \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @concurrent
    func save(_ snapshot: DiscoverCacheSnapshot) async {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Écriture impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Supprime le fichier de CETTE langue. Un fichier déjà absent n'est pas une erreur.
    @concurrent
    func clear() async {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Self.logger.error("Suppression impossible : \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Conversion

extension DiscoverCacheSnapshot {
    init(content: DiscoverContent, dates: [DiscoverTopic: Date], fallbackDate: Date) {
        self.init(sections: content.sections.map { section in
            Section(
                topic: section.topic.rawValue,
                fetchedAt: dates[section.topic] ?? fallbackDate,
                articles: section.articles.map { article in
                    Article(
                        title: article.title,
                        url: article.url,
                        snippet: article.snippet,
                        imageURL: article.imageURL?.absoluteString,
                        publishedAt: article.publishedAt,
                        sourceName: article.sourceName
                    )
                }
            )
        })
    }

    /// Contenu restauré, dans l'ordre du catalogue. Le filtrage de sécurité
    /// (`DiscoverViewModel.sanitized`) reste à appliquer : un fichier sur disque est
    /// une donnée externe, comme une réponse d'instance.
    func restored() -> (content: DiscoverContent, dates: [DiscoverTopic: Date]) {
        var dates: [DiscoverTopic: Date] = [:]
        var sectionsByTopic: [DiscoverTopic: DiscoverTopicSection] = [:]
        for section in sections {
            guard let topic = DiscoverTopic(rawValue: section.topic) else { continue }
            let articles = section.articles.map { article in
                DiscoverArticle(
                    topic: topic,
                    title: article.title,
                    url: article.url,
                    snippet: article.snippet,
                    imageURL: article.imageURL.flatMap { URL(string: $0) },
                    publishedAt: article.publishedAt,
                    sourceName: article.sourceName
                )
            }
            sectionsByTopic[topic] = DiscoverTopicSection(topic: topic, articles: articles)
            dates[topic] = section.fetchedAt
        }
        let ordered = DiscoverTopic.allCases.compactMap { sectionsByTopic[$0] }
        return (DiscoverContent(sections: ordered, failedTopics: []), dates)
    }
}
