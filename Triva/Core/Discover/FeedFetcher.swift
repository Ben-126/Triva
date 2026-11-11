//
//  FeedFetcher.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Pourquoi un flux n'a pas pu être lu. Le détail n'est jamais affiché : un flux en échec
/// laisse son sujet sans articles, et l'écran dit seulement que la source n'a pas répondu.
nonisolated enum FeedFetchError: Error, Sendable, Equatable {
    /// Pas de réponse : hors ligne, délai dépassé, serveur injoignable.
    case network
    /// Le serveur a répondu autre chose qu'un flux (403, 404, 429, 5xx…).
    case badStatus(Int)
    /// Réponse démesurée : un flux d'actualité fait quelques centaines de Ko.
    case tooLarge
    /// La réponse n'est pas un flux RSS ou Atom.
    case unreadable
}

/// Lit les articles d'un flux. Protocole d'injection comme `SearXNGSearching` : le vrai
/// lecteur passe par le réseau, les tests injectent des articles écrits d'avance.
nonisolated protocol FeedFetching: Sendable {
    func items(from source: FeedSource) async throws(FeedFetchError) -> [FeedItem]
}

/// Mémoire PARTAGÉE du processus pour les requêtes conditionnelles : pour chaque flux, les
/// derniers `ETag` / `Last-Modified` reçus et les articles qui allaient avec.
///
/// ## Pourquoi un acteur partagé, et rien sur disque
/// `DiscoverService` est recréé à chaque chargement (voir `TrivaRootCoordinator`) et ne
/// voit pas le cache disque du modèle : une mémoire propre à l'instance ne servirait jamais.
/// Un acteur unique garde ce qu'il faut pour répondre « rien de neuf » (HTTP 304) sans
/// retélécharger 800 Ko, et n'écrit rien : `LocalDataEraser` n'a donc rien de plus à effacer,
/// et une adresse de flux ne révèle rien sur l'utilisateur.
///
/// Les 5 minutes de fraîcheur évitent aussi de solliciter les éditeurs à chaque
/// tirer-pour-actualiser : un flux d'actualité n'a rien de neuf à si court intervalle, et
/// la politesse envers des serveurs qui nous laissent reprendre leur flux compte.
actor FeedRevalidationStore {
    static let shared = FeedRevalidationStore()

    /// Durée pendant laquelle un flux déjà lu est resservi sans requête.
    static let defaultFreshnessWindow: TimeInterval = 300

    nonisolated struct Entry: Sendable, Equatable {
        let etag: String?
        let lastModified: String?
        let items: [FeedItem]
        let storedAt: Date
    }

    private var entries: [URL: Entry] = [:]
    private let freshnessWindow: TimeInterval

    init(freshnessWindow: TimeInterval = FeedRevalidationStore.defaultFreshnessWindow) {
        self.freshnessWindow = freshnessWindow
    }

    func entry(for url: URL) -> Entry? {
        entries[url]
    }

    /// Articles à resservir sans requête, ou `nil` si l'entrée est absente ou périmée.
    func freshItems(for url: URL, now: Date) -> [FeedItem]? {
        guard let entry = entries[url], now.timeIntervalSince(entry.storedAt) < freshnessWindow else {
            return nil
        }
        return entry.items
    }

    func store(_ entry: Entry, for url: URL) {
        entries[url] = entry
    }

    /// Le serveur a confirmé (304) que l'entrée est toujours à jour : on la rajeunit.
    func renew(_ url: URL, now: Date) {
        guard let entry = entries[url] else { return }
        entries[url] = Entry(
            etag: entry.etag, lastModified: entry.lastModified, items: entry.items, storedAt: now
        )
    }
}

/// Lecteur de flux par HTTP, avec requêtes conditionnelles.
///
/// - Session sans cache disque (`URLSessionDataRequester.uncachedSession`) : le cache
///   système n'écrirait rien d'utile, et les validateurs sont gérés ici, à la main.
/// - `@concurrent` : téléchargement ET lecture du XML quittent le main actor. Un flux de
///   The Conversation pèse environ 800 Ko ; le lire sur le fil principal figerait l'écran.
/// - Aucune clé, aucun cookie, aucun identifiant utilisateur dans la requête.
nonisolated struct HTTPFeedFetcher: FeedFetching {
    /// Plafond de taille d'une réponse. Le plus gros flux du catalogue fait 0,8 Mo.
    static let maximumResponseBytes = 4_000_000
    static let requestTimeout: TimeInterval = 15

    private let requester: any HTTPDataRequesting
    private let store: FeedRevalidationStore
    private let now: @Sendable () -> Date

    init(
        requester: any HTTPDataRequesting = URLSessionDataRequester(),
        store: FeedRevalidationStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.requester = requester
        self.store = store
        self.now = now
    }

    @concurrent
    func items(from source: FeedSource) async throws(FeedFetchError) -> [FeedItem] {
        let url = source.url
        let start = now()
        if let fresh = await store.freshItems(for: url, now: start) { return fresh }

        let known = await store.entry(for: url)
        let (data, response) = try await download(Self.request(for: url, known: known))

        if response.statusCode == 304, let known {
            await store.renew(url, now: now())
            return known.items
        }
        guard (200..<300).contains(response.statusCode) else { throw .badStatus(response.statusCode) }
        guard data.count <= Self.maximumResponseBytes else { throw .tooLarge }

        let items: [FeedItem]
        do {
            items = try FeedParser.items(from: data)
        } catch {
            throw .unreadable
        }
        await store.store(
            FeedRevalidationStore.Entry(
                etag: response.value(forHTTPHeaderField: "ETag"),
                lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                items: items,
                storedAt: now()
            ),
            for: url
        )
        return items
    }

    private func download(_ request: URLRequest) async throws(FeedFetchError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await requester.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FeedFetchError.network }
            return (data, http)
        } catch {
            throw .network
        }
    }

    /// `If-None-Match` / `If-Modified-Since` seulement si on a déjà les articles qui vont
    /// avec : un 304 sans rien à resservir ne servirait à rien.
    static func request(for url: URL, known: FeedRevalidationStore.Entry?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(
            "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Triva/1.0 (lecteur de flux)", forHTTPHeaderField: "User-Agent")
        if let known {
            if let etag = known.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified = known.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }
        return request
    }
}
