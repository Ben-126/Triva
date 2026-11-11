//
//  PrivacyCleanupTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

// MARK: - Outils

/// Dossier jetable pour un `URLCache` de test : jamais le vrai `Cache.db`.
private func makeTemporaryCacheDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "triva-cache-test-\(UUID().uuidString)")
}

/// Range une réponse bidon dans `cache` pour `url`.
private func store(_ url: URL, in cache: URLCache) throws {
    let request = URLRequest(url: url)
    let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=3600"])
    )
    cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("corps".utf8)), for: request)
}

private func isCached(_ url: URL, in cache: URLCache) -> Bool {
    cache.cachedResponse(for: URLRequest(url: url)) != nil
}

private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "test.privacyCleanup.\(UUID().uuidString)"))
}

/// Faux cache Découvrir : compte les `clear()`.
private final class SpyDiscoverCache: DiscoverContentCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var _clearCount = 0
    var clearCount: Int { lock.withLock { _clearCount } }

    func load() async -> DiscoverCacheSnapshot? { nil }
    func save(_ snapshot: DiscoverCacheSnapshot) async {}
    func clear() async { lock.withLock { _clearCount += 1 } }
}

/// Trousseau fixe : la clé doit survivre à « Tout effacer ».
private struct FixedKeyStore: APIKeyStoring {
    let key: String
    func apiKey(account: String) throws -> String? { key }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

// MARK: - Purge unique du cache HTTP

@Suite("URLCachePurger")
struct URLCachePurgerTests {
    @Test("La première fois, vide le cache et pose le drapeau")
    func purgesOnFirstRun() async throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: makeTemporaryCacheDirectory())
        let url = try #require(URL(string: "https://searx.example/search?q=ma+question+privee"))
        try store(url, in: cache)
        #expect(isCached(url, in: cache))
        let defaults = try makeDefaults()

        let purged = await URLCachePurger(defaults: defaults, cache: cache).purgeIfNeeded()

        #expect(purged)
        #expect(!isCached(url, in: cache))
        #expect(defaults.bool(forKey: URLCachePurger.completedFlagKey))
    }

    @Test("Une seule fois par installation : le second lancement ne touche plus au cache")
    func purgesOnlyOnce() async throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: makeTemporaryCacheDirectory())
        let defaults = try makeDefaults()
        let purger = URLCachePurger(defaults: defaults, cache: cache)
        await purger.purgeIfNeeded()

        let url = try #require(URL(string: "https://exemple.fr/apres-la-purge"))
        try store(url, in: cache)
        let purgedAgain = await purger.purgeIfNeeded()

        #expect(!purgedAgain)
        #expect(isCached(url, in: cache))
    }

    @Test("Ne touche à rien d'autre que le cache : les autres préférences restent intactes")
    func leavesOtherPreferencesAlone() async throws {
        let defaults = try makeDefaults()
        defaults.set("valeur", forKey: "autre.reglage")

        await URLCachePurger(defaults: defaults, cache: URLCache(memoryCapacity: 0, diskCapacity: 0)).purgeIfNeeded()

        #expect(defaults.string(forKey: "autre.reglage") == "valeur")
    }

    @Test("La purge s'exécute hors du fil principal")
    func purgeRunsOffTheMainThread() async throws {
        // Le point d'entrée est `@concurrent` : appelé depuis le main actor, il
        // doit quand même quitter le fil principal (sinon vider la base SQLite
        // bloquerait le lancement). On le vérifie par un cache espion.
        final class ThreadSpyCache: URLCache, @unchecked Sendable {
            nonisolated(unsafe) var removedOnMainThread: Bool?
            override func removeAllCachedResponses() {
                removedOnMainThread = Thread.isMainThread
                super.removeAllCachedResponses()
            }
        }
        let cache = ThreadSpyCache(memoryCapacity: 0, diskCapacity: 0)

        await URLCachePurger(defaults: try makeDefaults(), cache: cache).purgeIfNeeded()

        #expect(cache.removedOnMainThread == false)
    }
}

// MARK: - Sessions par défaut sans cache

@Suite("Sessions par défaut sans cache")
struct DefaultSessionsHaveNoCacheTests {
    @Test("SearXNGClient : la session par défaut n'a pas de URLCache")
    func searxngClientDefaultSessionIsUncached() {
        #expect(SearXNGClient().urlSession.configuration.urlCache == nil)
    }

    @Test("URLSessionFetcher (widget météo) : la session par défaut n'a pas de URLCache")
    func urlSessionFetcherDefaultSessionIsUncached() {
        #expect(URLSessionFetcher().urlSession.configuration.urlCache == nil)
    }

    @Test("Témoin : URLSession.shared, elle, a bien un cache (le test ci-dessus n'est pas vide)")
    func sharedSessionHasACache() {
        #expect(URLSession.shared.configuration.urlCache != nil)
    }
}

// MARK: - « Tout effacer »

@MainActor
@Suite("LocalDataEraser")
struct LocalDataEraserTests {
    private func makeStores(keyStore: any APIKeyStoring = FixedKeyStore(key: "sk-secret")) throws -> TrivaSharedStores {
        let userDefaults = try makeDefaults()
        return TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(
                defaultInstances: [URL(string: "https://searx.example")!],
                userDefaults: userDefaults
            ),
            keyStore: keyStore
        )
    }

    @Test("Efface conversations, favoris et caches ; garde la clé et le choix du moteur")
    func erasesDataButKeepsKeysAndEngine() async throws {
        let stores = try makeStores()
        stores.engineSettings.selectedOption = .cloudBYOK
        let conversation = try stores.chatHistory.createConversation(firstQuestion: "Question privée")
        try stores.chatHistory.appendUserMessage(to: conversation, text: "Question privée")
        let answer = try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Réponse")
        try stores.favorites.toggle(answer)

        let urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: makeTemporaryCacheDirectory())
        let url = try #require(URL(string: "https://searx.example/search?q=question+privee"))
        try store(url, in: urlCache)
        let discover = SpyDiscoverCache()
        let eraser = LocalDataEraser(
            chatHistory: stores.chatHistory,
            favorites: stores.favorites,
            discoverCache: discover,
            urlCache: urlCache
        )

        try await eraser.eraseAll()

        #expect(try stores.chatHistory.conversations().isEmpty)
        #expect(try stores.favorites.favorites().isEmpty)
        #expect(!isCached(url, in: urlCache))
        #expect(discover.clearCount == 1)
        #expect(try stores.keyStore.apiKey(account: "openai") == "sk-secret")
        #expect(stores.engineSettings.selectedOption == .cloudBYOK)
    }

    @Test("L'effacement incrémente la révision de l'historique (le chat ouvert se vide)")
    func bumpsHistoryRevision() async throws {
        let stores = try makeStores()
        _ = try stores.chatHistory.createConversation(firstQuestion: "Q")
        let before = stores.chatHistory.revision

        try await LocalDataEraser(
            chatHistory: stores.chatHistory,
            favorites: stores.favorites,
            discoverCache: SpyDiscoverCache(),
            urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        ).eraseAll()

        #expect(stores.chatHistory.revision > before)
    }

    @Test("Sur des données vides, ne plante pas")
    func eraseOnEmptyStoresIsSafe() async throws {
        let stores = try makeStores()
        try await LocalDataEraser(
            chatHistory: stores.chatHistory,
            favorites: stores.favorites,
            discoverCache: SpyDiscoverCache(),
            urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        ).eraseAll()
        #expect(try stores.chatHistory.conversations().isEmpty)
    }
}

@Suite("DiscoverDiskCache.clear")
struct DiscoverDiskCacheClearTests {
    @Test("Supprime le fichier, et un fichier absent n'est pas une erreur")
    func clearRemovesFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "discover-test-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: fileURL)
        let cache = DiscoverDiskCache(fileURL: fileURL)

        await cache.clear()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        await cache.clear()
    }
}
