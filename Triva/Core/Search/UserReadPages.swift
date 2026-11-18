//
//  UserReadPages.swift
//  Triva
//
//  « Lire cette page » : une source que le site refuse à la lecture AUTOMATIQUE (robots.txt,
//  X-Robots-Tag noai, tdm-reservation) peut être lue À LA DEMANDE de l'utilisateur, comme le ferait
//  un navigateur (décision de Ben, 2026-11-17). Ce fichier porte la mémoire de ces demandes.
//

import Foundation
import Observation
import os

/// Pages que l'utilisateur a fait lire lui-même. En mémoire seulement (jamais sur disque), bornées.
/// `ScrapeService` la consulte avant tout réseau : une page déjà lue sur demande sert de contexte
/// aux questions suivantes de la conversation, sans nouvelle requête ni nouveau refus.
nonisolated enum UserReadPages {
    static let maxPages = 20
    private static let storage = OSAllocatedUnfairLock(initialState: [(key: String, page: ScrapedPage)]())

    static func page(for url: String) -> ScrapedPage? {
        let key = SourceRanker.normalizedURLKey(for: url)
        return storage.withLock { pages in pages.first { $0.key == key }?.page }
    }

    static func store(_ page: ScrapedPage) {
        guard page.succeeded else { return }
        let key = SourceRanker.normalizedURLKey(for: page.url)
        storage.withLock { pages in
            pages.removeAll { $0.key == key }
            pages.append((key, page))
            if pages.count > maxPages { pages.removeFirst(pages.count - maxPages) }
        }
    }

    /// À appeler par « Tout effacer ».
    static func removeAll() { storage.withLock { $0.removeAll() } }
}

/// État, observable par l'interface, des sources dont la lecture automatique a été refusée.
@Observable
final class SiteReadRefusals {
    nonisolated enum State: Equatable, Sendable {
        /// Refusée par le site : le bouton « Lire cette page » est proposé.
        case refused
        case reading
        /// Lue à la demande de l'utilisateur.
        case read
        /// La page n'a pas pu être lue (réseau, page vide, mur anti-robot…).
        case readFailed
    }

    static let shared = SiteReadRefusals()

    private var states: [String: State] = [:]

    func state(for url: String) -> State? {
        states[SourceRanker.normalizedURLKey(for: url)]
    }

    func isRefused(_ url: String) -> Bool { state(for: url) != nil }

    /// Appelable depuis n'importe quel contexte : le marquage se fait sur le main actor.
    nonisolated static func record(_ pages: [ScrapedPage]) {
        let urls = pages.filter(\.refusedBySite).map(\.url)
        guard !urls.isEmpty else { return }
        Task { @MainActor in shared.markRefused(urls) }
    }

    func markRefused(_ urls: [String]) {
        for url in urls {
            let key = SourceRanker.normalizedURLKey(for: url)
            // Une page déjà lue ou en cours de lecture garde son état.
            if states[key] == nil || states[key] == .readFailed { states[key] = .refused }
        }
    }

    /// Lecture demandée par l'utilisateur : même User-Agent honnête, `robots.txt` non appliqué.
    func readPage(url: String, service: ScrapeService = ScrapeService()) async {
        let key = SourceRanker.normalizedURLKey(for: url)
        guard states[key] != .reading else { return }
        states[key] = .reading
        let page = await service.readOnUserRequest(url: url)
        if page.succeeded {
            UserReadPages.store(page)
            states[key] = .read
        } else {
            states[key] = .readFailed
        }
    }

    func removeAll() { states.removeAll() }
}

/// Textes de « Lire cette page » (validé par Ben le 2026-11-18, texte légal : sobres, sans mention juridique).
nonisolated enum ReadPagePresentation {
    // Validé par Ben le 2026-11-18 (texte légal)
    static let refusedLabel = "lecture refusée par le site"
    static let buttonTitle = "Lire cette page"
    static let readingLabel = "Lecture…"
    static let readLabel = "page lue"
    static let failedLabel = "lecture impossible"

    static func buttonAccessibilityLabel(title: String) -> String {
        "Lire la page « \(title) » : le site a refusé la lecture automatique"
    }
}
