//
//  EraseAllDataTests.swift
//  TrivaTests
//
//  Mission C6 (décision de Ben, 2026-11-14) : « Tout effacer » passe par ModelContainer.deleteAllData(),
//  puis le stockage recrée un conteneur neuf et rebranche les stores. Remplace le banc K7
//  (DeleteAllDataBenchTests), dont la méthode de scan des octets est reprise ici.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

/// Base sur disque jetable : un dossier à part, jamais le `TrivaLocalStore` de l'utilisateur.
@MainActor
private struct DiskFixture {
    let directory: URL
    let storeURL: URL
    let marker = "C6MARQUEUR-\(UUID().uuidString)"

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "triva-c6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appending(path: "Erase.store")
    }

    func open() throws -> ModelContainer {
        let schema = Schema(TrivaModelContainer.models)
        let configuration = ModelConfiguration("TrivaC6Erase", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Occurrences du marqueur dans TOUS les fichiers de la base (`.store`, `-wal`, `-shm`), en octets bruts.
    func markerOccurrences() -> Int {
        let needle = Data(marker.utf8)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { total, name in
            let data = (try? Data(contentsOf: directory.appending(path: name))) ?? Data()
            var count = 0
            var cursor = data.startIndex
            while let range = data.range(of: needle, in: cursor..<data.endIndex) {
                count += 1
                cursor = range.upperBound
            }
            return total + count
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Stockage de l'app sur le fichier jetable, avec les mêmes réessais qu'au lancement (sans pause).
@MainActor
private func makeStorage(
    _ fixture: DiskFixture,
    openFailsAfter allowedOpenings: Int = .max,
    dataDeleter: @escaping @MainActor (ModelContainer) throws -> Void = { try $0.deleteAllData() }
) -> TrivaStorage {
    var openings = 0
    return TrivaStorage(
        opener: {
            openings += 1
            if openings > allowedOpenings { throw TrivaModelContainerError.creationFailed("panne simulée") }
            return try fixture.open()
        },
        retryDelaysMilliseconds: [],
        pause: { _ in },
        dataDeleter: dataDeleter
    )
}

private struct SimulatedDeletionFailure: Error {}

@MainActor
private func seed(_ history: ChatHistoryStore, _ favorites: FavoritesStore, marker: String) throws {
    let conversation = try history.createConversation(title: "Sujet \(marker)")
    for index in 0..<10 {
        try history.appendUserMessage(to: conversation, text: "Question \(index) \(marker)")
    }
    let answer = try history.appendAssistantMessage(to: conversation, text: "Réponse \(marker)")
    try favorites.toggle(answer)
}

@MainActor
private func makeEraser(
    _ history: ChatHistoryStore,
    _ favorites: FavoritesStore,
    storage: TrivaStorage?,
    beforeErase: (@MainActor () async -> Void)? = nil
) -> LocalDataEraser {
    LocalDataEraser(
        chatHistory: history,
        favorites: favorites,
        discoverCache: DiscoverNoCache(),
        urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
        storage: storage,
        beforeErase: beforeErase
    )
}

@MainActor
@Suite("Tout effacer : deleteAllData et conteneur recréé")
struct EraseAllDataTests {
    @Test("Aucune trace du marqueur dans .store/-wal/-shm juste après l'effacement ; conversations et favoris vides puis réécrivables sans plantage")
    func erasesEverythingThenAcceptsWrites() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let storage = makeStorage(fixture)
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        try seed(history, favorites, marker: fixture.marker)
        #expect(fixture.markerOccurrences() > 0)
        let revisionBefore = history.revision

        try await makeEraser(history, favorites, storage: storage).eraseAll()

        #expect(fixture.markerOccurrences() == 0)
        #expect(try history.conversations().isEmpty)
        #expect(try favorites.favorites().isEmpty)
        #expect(history.revision > revisionBefore)
        #expect(storage.isAvailable)

        // Les stores déjà branchés écrivent sur le conteneur neuf (avant le correctif : plantage).
        let conversation = try history.createConversation(firstQuestion: "Après effacement")
        let answer = try history.appendAssistantMessage(to: conversation, text: "Réponse neuve")
        try favorites.toggle(answer)
        #expect(try history.conversations().map(\.title) == ["Après effacement"])
        #expect(try favorites.favorites().count == 1)
        // Un contexte neuf sur le conteneur courant voit la même chose : l'écriture a atteint le disque.
        let fresh = ModelContext(storage.container)
        #expect(try fresh.fetchCount(FetchDescriptor<StoredConversation>()) == 1)
    }

    @Test("Le repli objet par objet (sans stockage rouvrable) laisse des traces dans les fichiers : c'est ce que deleteAllData corrige")
    func objectByObjectDeletionLeavesTraces() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let storage = TrivaStorage(container: try fixture.open())
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        try seed(history, favorites, marker: fixture.marker)

        try await makeEraser(history, favorites, storage: storage).eraseAll()

        #expect(try history.conversations().isEmpty)
        #expect(fixture.markerOccurrences() > 0)
    }

    @Test("deleteAllData échoue : repli objet par objet, tout est quand même effacé, aucune erreur")
    func deletionFailureFallsBackToObjectByObject() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let storage = makeStorage(fixture, dataDeleter: { _ in throw SimulatedDeletionFailure() })
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        try seed(history, favorites, marker: fixture.marker)

        try await makeEraser(history, favorites, storage: storage).eraseAll()

        #expect(try history.conversations().isEmpty)
        #expect(try favorites.favorites().isEmpty)
        _ = try history.createConversation(firstQuestion: "Toujours écrivable")
    }

    @Test("deleteAllData échoue ET la base ne rouvre pas : « incomplet » pour les deux étapes, message honnête")
    func deletionAndReopeningFailureIsReportedAsIncomplete() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let storage = makeStorage(fixture, openFailsAfter: 1, dataDeleter: { _ in throw SimulatedDeletionFailure() })
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        try seed(history, favorites, marker: fixture.marker)

        var thrown: LocalDataEraseError?
        do {
            try await makeEraser(history, favorites, storage: storage).eraseAll()
        } catch {
            thrown = error
        }

        #expect(thrown == .incomplete(failedSteps: [.favorites, .history]))
        #expect(!storage.isAvailable)
        let message = LocalDataEraseSection.incompleteMessage(failedSteps: thrown?.failedSteps ?? [])
        #expect(message.contains("n'ont pas pu être effacés"))
    }

    @Test("Effacement réussi mais réouverture impossible : les données SONT effacées, pas d'erreur ; le stockage se dit indisponible")
    func reopeningFailureAfterSuccessfulErasureIsNotAnEraseError() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let storage = makeStorage(fixture, openFailsAfter: 1)
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        try seed(history, favorites, marker: fixture.marker)

        try await makeEraser(history, favorites, storage: storage).eraseAll()

        #expect(fixture.markerOccurrences() == 0)
        #expect(!storage.isAvailable)
        #expect(throws: ChatHistoryStoreError.self) { try history.conversations() }
    }

    @Test("beforeErase tourne AVANT l'effacement : les données existent encore à cet instant")
    func beforeEraseRunsFirst() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let storage = makeStorage(fixture)
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        try seed(history, favorites, marker: fixture.marker)
        var countSeenByHook: Int?

        try await makeEraser(history, favorites, storage: storage, beforeErase: {
            countSeenByHook = try? history.conversations().count
        }).eraseAll()

        #expect(countSeenByHook == 1)
        #expect(try history.conversations().isEmpty)
    }

    @Test("Un conteneur injecté (tests, aperçus) ne sait pas se rouvrir : eraseAllData le dit, le repli prend le relais")
    func injectedContainerReportsReopeningNotSupported() throws {
        let storage = TrivaStorage(container: try TrivaModelContainer.makeInMemory())
        #expect(throws: TrivaStorage.EraseError.reopeningNotSupported) { try storage.eraseAllData() }
    }
}
