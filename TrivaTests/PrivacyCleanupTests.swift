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
    try #require(TestDefaults.suite(named: "test.privacyCleanup.\(UUID().uuidString)"))
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

/// Trousseau en mémoire qui applique VRAIMENT les suppressions : un test qui
/// vérifie « la clé survit à Tout effacer » doit pouvoir échouer si
/// l'effacement la supprimait (un faux qui répond toujours la même clé passait
/// quoi qu'il arrive).
private final class DictionaryKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private var _deletions: [String] = []

    init(keys: [String: String]) { self.keys = keys }

    var deletions: [String] { lock.withLock { _deletions } }

    func apiKey(account: String) throws -> String? { lock.withLock { keys[account] } }
    func save(apiKey: String, account: String) throws { lock.withLock { keys[account] = apiKey } }
    func deleteAPIKey(account: String) throws {
        lock.withLock {
            keys[account] = nil
            _deletions.append(account)
        }
    }
}

/// Étape de suppression qui compte ses appels, et peut échouer.
@MainActor
private final class StubDeleter: AllDeleting {
    struct Failure: Error {}
    private(set) var callCount = 0
    private let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    func deleteAll() throws {
        callCount += 1
        if fails { throw Failure() }
    }
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
        // En mémoire seulement : avec un cache disque, `removeAllCachedResponses()` peut finir de vider
        // le disque APRÈS le retour et emporter l'entrée stockée juste ensuite (échec intermittent
        // vu une fois sous la charge de la suite complète, 2026-11-13).
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
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
    private func makeStores(keyStore: any APIKeyStoring) throws -> TrivaSharedStores {
        let userDefaults = try makeDefaults()
        return TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(
                defaultInstances: [URL(string: "https://searx.example")!],
                userDefaults: userDefaults
            ),
            keyStore: keyStore
        )
    }

    private func makeDictionaryStores() throws -> (TrivaSharedStores, DictionaryKeyStore) {
        let keyStore = DictionaryKeyStore(keys: ["openai": "sk-secret", "custom:42": "sk-other"])
        return (try makeStores(keyStore: keyStore), keyStore)
    }

    @Test("Efface conversations, favoris et caches par la fabrique RÉELLE ; garde les clés (aucune suppression) et le choix du moteur")
    func erasesDataButKeepsKeysAndEngine() async throws {
        let (stores, keyStore) = try makeDictionaryStores()
        stores.engineSettings.selectedOption = .cloudBYOK
        let conversation = try stores.chatHistory.createConversation(firstQuestion: "Question privée")
        try stores.chatHistory.appendUserMessage(to: conversation, text: "Question privée")
        let answer = try stores.chatHistory.appendAssistantMessage(to: conversation, text: "Réponse")
        try stores.favorites.toggle(answer)

        let urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: makeTemporaryCacheDirectory())
        let url = try #require(URL(string: "https://searx.example/search?q=question+privee"))
        try store(url, in: urlCache)

        // La fabrique de l'app, avec un cache HTTP jetable (jamais le vrai) ; le cache Découvrir est
        // celui par défaut des tests (`DiscoverNoCache`), qui ne touche aucun fichier.
        try await stores.makeLocalDataEraser(urlCache: urlCache).eraseAll()

        #expect(try stores.chatHistory.conversations().isEmpty)
        #expect(try stores.favorites.favorites().isEmpty)
        #expect(!isCached(url, in: urlCache))
        #expect(try stores.keyStore.apiKey(account: "openai") == "sk-secret")
        #expect(try stores.keyStore.apiKey(account: "custom:42") == "sk-other")
        #expect(keyStore.deletions.isEmpty)
        #expect(stores.engineSettings.selectedOption == .cloudBYOK)
    }

    @Test("Le cache Découvrir est vidé une fois")
    func clearsTheDiscoverCache() async throws {
        let (stores, _) = try makeDictionaryStores()
        let discover = SpyDiscoverCache()

        try await LocalDataEraser(
            chatHistory: stores.chatHistory,
            favorites: stores.favorites,
            discoverCache: discover,
            urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        ).eraseAll()

        #expect(discover.clearCount == 1)
    }

    @Test("L'effacement incrémente la révision de l'historique (le chat ouvert se vide)")
    func bumpsHistoryRevision() async throws {
        let (stores, _) = try makeDictionaryStores()
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
        let (stores, _) = try makeDictionaryStores()
        try await LocalDataEraser(
            chatHistory: stores.chatHistory,
            favorites: stores.favorites,
            discoverCache: SpyDiscoverCache(),
            urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        ).eraseAll()
        #expect(try stores.chatHistory.conversations().isEmpty)
    }

    // MARK: Échec partiel (R4-3)

    /// Joue l'effacement avec ces deux étapes et renvoie ce qu'il a levé, avec l'état des caches.
    private func erase(
        history: StubDeleter,
        favorites: StubDeleter
    ) async throws -> (error: LocalDataEraseError?, discover: SpyDiscoverCache, httpCacheEmpty: Bool) {
        let urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: makeTemporaryCacheDirectory())
        let url = try #require(URL(string: "https://searx.example/search?q=question+privee"))
        try store(url, in: urlCache)
        let discover = SpyDiscoverCache()
        let eraser = LocalDataEraser(
            chatHistory: history, favorites: favorites, discoverCache: discover, urlCache: urlCache
        )
        do {
            try await eraser.eraseAll()
            return (nil, discover, !isCached(url, in: urlCache))
        } catch {
            return (error, discover, !isCached(url, in: urlCache))
        }
    }

    @Test("Les favoris échouent : .incomplete([favoris]), l'historique est quand même effacé, les deux caches sont vidés")
    func failingFavoritesStillErasesTheRest() async throws {
        let history = StubDeleter()
        let favorites = StubDeleter(fails: true)

        let outcome = try await erase(history: history, favorites: favorites)

        #expect(outcome.error == .incomplete(failedSteps: [.favorites]))
        #expect(history.callCount == 1)
        #expect(outcome.discover.clearCount == 1)
        #expect(outcome.httpCacheEmpty)
    }

    @Test("L'historique échoue : .incomplete([historique]), les favoris sont effacés, les deux caches sont vidés")
    func failingHistoryStillErasesTheRest() async throws {
        let history = StubDeleter(fails: true)
        let favorites = StubDeleter()

        let outcome = try await erase(history: history, favorites: favorites)

        #expect(outcome.error == .incomplete(failedSteps: [.history]))
        #expect(favorites.callCount == 1)
        #expect(outcome.discover.clearCount == 1)
        #expect(outcome.httpCacheEmpty)
    }

    @Test("Tout échoue : les deux étapes sont signalées, et le cache HTTP (questions en clair) part quand même")
    func everythingFailingStillClearsTheCaches() async throws {
        let outcome = try await erase(history: StubDeleter(fails: true), favorites: StubDeleter(fails: true))

        #expect(outcome.error == .incomplete(failedSteps: [.favorites, .history]))
        #expect(outcome.discover.clearCount == 1)
        #expect(outcome.httpCacheEmpty)
    }

    // MARK: Base inaccessible (R2-2, décision de Ben)

    @Test("Base inaccessible : « Tout effacer » lève .incomplete, jamais un succès ; les caches partent, rien n'est supprimé sur disque")
    func unavailableStorageIsNeverReportedAsErased() async throws {
        let storage = TrivaStorage(
            opener: { throw TrivaModelContainerError.creationFailed("panne simulée") },
            retryDelaysMilliseconds: [],
            pause: { _ in }
        )
        let userDefaults = try makeDefaults()
        let stores = TrivaSharedStores(
            userDefaults: userDefaults,
            storage: storage,
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
            keyStore: DictionaryKeyStore(keys: [:])
        )
        let urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: makeTemporaryCacheDirectory())
        let url = try #require(URL(string: "https://searx.example/search?q=question+privee"))
        try store(url, in: urlCache)

        var thrown: LocalDataEraseError?
        do {
            try await stores.makeLocalDataEraser(urlCache: urlCache).eraseAll()
        } catch {
            thrown = error
        }

        #expect(thrown == .incomplete(failedSteps: [.favorites, .history]))
        #expect(!isCached(url, in: urlCache))
    }

    @Test("Le message de l'écran dit ce qui n'a PAS été effacé, et ce qui l'a été")
    func incompleteMessagesNameWhatRemains() {
        let both = LocalDataEraseSection.incompleteMessage(failedSteps: [.favorites, .history])
        let onlyFavorites = LocalDataEraseSection.incompleteMessage(failedSteps: [.favorites])
        let onlyHistory = LocalDataEraseSection.incompleteMessage(failedSteps: [.history])

        #expect(both.contains("conversations et tes favoris n'ont pas pu être effacés"))
        #expect(both.contains("Seuls les caches"))
        #expect(onlyFavorites.contains("favoris n'ont pas pu être effacés"))
        #expect(onlyFavorites.contains("conversations et les caches de recherche l'ont été"))
        #expect(onlyHistory.contains("conversations n'ont pas pu être effacées"))
        #expect(onlyHistory.contains("favoris et les caches de recherche l'ont été"))
        for message in [both, onlyFavorites, onlyHistory] {
            #expect(!message.contains("Tout a été effacé"))
        }
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
