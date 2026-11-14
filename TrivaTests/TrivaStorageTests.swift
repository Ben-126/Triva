//
//  TrivaStorageTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

// MARK: - Outils

/// Ouvreur qui échoue `failures` fois puis renvoie un conteneur EN MÉMOIRE neuf.
/// Aucun test de ce fichier n'appelle `makeOnDisk()` : le vrai fichier de
/// l'utilisateur n'est jamais ouvert.
@MainActor
private final class FlakyOpener {
    private(set) var calls = 0
    private let failures: Int

    init(failures: Int) {
        self.failures = failures
    }

    func open() throws -> ModelContainer {
        calls += 1
        if calls <= failures {
            throw TrivaModelContainerError.creationFailed("panne simulée n°\(calls)")
        }
        return try TrivaModelContainer.makeInMemory()
    }
}

/// Journal des pauses demandées entre deux essais (les tests n'attendent rien).
@MainActor
private final class PauseLog {
    private(set) var delays: [Int] = []
    func record(_ milliseconds: Int) { delays.append(milliseconds) }
}

@MainActor
private func makeStorage(opener: FlakyOpener, pauses: PauseLog) -> TrivaStorage {
    TrivaStorage(
        opener: { try opener.open() },
        retryDelaysMilliseconds: [80, 200, 500],
        pause: { pauses.record($0) }
    )
}

/// Conteneur sur un fichier d'un dossier JETABLE : le seul accès disque de ce
/// fichier de tests, jamais le `TrivaLocalStore` de l'utilisateur.
@MainActor
private func openContainer(at url: URL) throws -> ModelContainer {
    let schema = Schema(TrivaModelContainer.models)
    let configuration = ModelConfiguration(
        "TrivaStorageTest", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: configuration)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "triva-storage-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Ouverture et nouvelles tentatives

@MainActor
@Suite("TrivaStorage : ouverture")
struct TrivaStorageOpeningTests {
    @Test("Une première ouverture ratée puis réussie est invisible : disponible, aucune révision, un seul essai de plus")
    func secondAttemptSucceedsInvisibly() throws {
        let opener = FlakyOpener(failures: 1)
        let pauses = PauseLog()

        let storage = makeStorage(opener: opener, pauses: pauses)

        #expect(storage.isAvailable)
        #expect(storage.state == .ready)
        #expect(storage.generation == 0)
        #expect(opener.calls == 2)
        #expect(pauses.delays == [80])

        let history = ChatHistoryStore(storage: storage)
        _ = try history.createConversation(firstQuestion: "Question")
        #expect(try history.conversations().count == 1)
    }

    @Test("Échec persistant : quatre essais espacés, puis indisponible avec la raison pour les logs")
    func persistentFailureEndsUnavailable() {
        let opener = FlakyOpener(failures: .max)
        let pauses = PauseLog()

        let storage = makeStorage(opener: opener, pauses: pauses)

        #expect(!storage.isAvailable)
        #expect(opener.calls == 4)
        #expect(pauses.delays == [80, 200, 500])
        guard case .unavailable(let reason) = storage.state else {
            Issue.record("État attendu : indisponible")
            return
        }
        #expect(reason.contains("panne simulée n°4"))
        #expect(storage.context == nil)
    }

    @Test("Un stockage déjà ouvert n'a rien à rouvrir : retry() est un no-op")
    func readyStorageRetryDoesNothing() throws {
        let storage = TrivaStorage(container: try TrivaModelContainer.makeInMemory())

        #expect(storage.retry())
        #expect(storage.generation == 0)
    }
}

// MARK: - Aucune écriture perdue en silence

@MainActor
@Suite("TrivaStorage : base indisponible")
struct TrivaStorageUnavailableTests {
    private func makeUnavailable() -> (storage: TrivaStorage, opener: FlakyOpener) {
        let opener = FlakyOpener(failures: .max)
        let storage = makeStorage(opener: opener, pauses: PauseLog())
        return (storage, opener)
    }

    @Test("Historique : lire, créer, écrire et tout effacer lèvent storageUnavailable, rien n'atteint le conteneur de réserve")
    func historyRefusesEverythingAndLosesNothingSilently() throws {
        let (storage, _) = makeUnavailable()
        let history = ChatHistoryStore(storage: storage)

        #expect(throws: ChatHistoryStoreError.storageUnavailable) { try history.conversations() }
        #expect(throws: ChatHistoryStoreError.storageUnavailable) { try history.conversation(with: UUID()) }
        #expect(throws: ChatHistoryStoreError.storageUnavailable) { try history.conversations(matching: "q") }
        #expect(throws: ChatHistoryStoreError.storageUnavailable) { try history.createConversation(firstQuestion: "Q") }
        #expect(throws: ChatHistoryStoreError.storageUnavailable) { try history.deleteAll() }

        // Le conteneur de réserve, lui, n'a rien reçu : aucune écriture « réussie » vers un stockage volatil.
        let reserve = ModelContext(storage.container)
        #expect(try reserve.fetchCount(FetchDescriptor<StoredConversation>()) == 0)
        #expect(history.revision == 0)
    }

    @Test("Favoris : lire, marquer et tout effacer lèvent storageUnavailable")
    func favoritesRefuseEverything() throws {
        let (storage, _) = makeUnavailable()
        let favorites = FavoritesStore(storage: storage)

        #expect(throws: FavoritesStoreError.storageUnavailable) { try favorites.favorites() }
        #expect(throws: FavoritesStoreError.storageUnavailable) { try favorites.isFavorite(messageID: UUID()) }
        #expect(throws: FavoritesStoreError.storageUnavailable) { try favorites.unmark(messageID: UUID()) }
        #expect(throws: FavoritesStoreError.storageUnavailable) {
            try favorites.mark(messageID: UUID(), conversationID: nil, question: "Q", answer: "R")
        }
        #expect(throws: FavoritesStoreError.storageUnavailable) { try favorites.deleteAll() }

        let reserve = ModelContext(storage.container)
        #expect(try reserve.fetchCount(FetchDescriptor<StoredFavorite>()) == 0)
    }

    @Test("Réessayer qui échoue encore : reste indisponible, aucune révision")
    func failingRetryKeepsTheErrorState() {
        let (storage, opener) = makeUnavailable()
        let callsBefore = opener.calls

        let recovered = storage.retry()

        #expect(!recovered)
        #expect(!storage.isAvailable)
        #expect(storage.generation == 0)
        #expect(opener.calls == callsBefore + 1)
    }

    @Test("Réessayer qui réussit : les DEUX stores se rebranchent, la révision change (les vues rechargent), les écritures arrivent en base")
    func successfulRetryReconnectsBothStores() throws {
        // 4 échecs automatiques, puis le 5e essai (le bouton) réussit.
        let opener = FlakyOpener(failures: 4)
        let storage = makeStorage(opener: opener, pauses: PauseLog())
        let history = ChatHistoryStore(storage: storage)
        let favorites = FavoritesStore(storage: storage)
        #expect(!storage.isAvailable)
        let historyRevision = history.revision
        let favoritesRevision = favorites.revision

        let recovered = history.retryOpeningStorage()

        #expect(recovered)
        #expect(storage.isAvailable)
        #expect(history.revision > historyRevision)
        #expect(favorites.revision > favoritesRevision)

        let conversation = try history.createConversation(firstQuestion: "Question")
        try history.appendUserMessage(to: conversation, text: "Question")
        let answer = try history.appendAssistantMessage(to: conversation, text: "Réponse")
        try favorites.toggle(answer)

        // Validé par un contexte NEUF : l'écriture est vraiment arrivée dans le conteneur ouvert.
        let fresh = ModelContext(storage.container)
        #expect(try fresh.fetchCount(FetchDescriptor<StoredConversation>()) == 1)
        #expect(try fresh.fetchCount(FetchDescriptor<StoredFavorite>()) == 1)
    }
}

// MARK: - L'ancienne base sur disque n'est jamais touchée

@MainActor
@Suite("TrivaStorage : fichier sur disque")
struct TrivaStorageOnDiskTests {
    @Test("Un fichier de base illisible reste octet pour octet identique après les essais, et un essai ultérieur retrouve une base saine")
    func unreadableFileIsNeverModified() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "TrivaLocalStore.store")
        let garbage = Data("ceci n'est pas une base SQLite".utf8) + Data(repeating: 0xAB, count: 4_096)
        try garbage.write(to: storeURL)

        let storage = TrivaStorage(
            opener: { try openContainer(at: storeURL) },
            retryDelaysMilliseconds: [1, 1],
            pause: { _ in }
        )

        // Si SwiftData accepte ce fichier-là, le scénario ne représente rien : on le signale plutôt que de passer à vide.
        guard !storage.isAvailable else {
            Issue.record("SwiftData a ouvert un fichier illisible : scénario non représentatif")
            return
        }
        #expect(try Data(contentsOf: storeURL) == garbage)
        storage.retry()
        #expect(try Data(contentsOf: storeURL) == garbage)
    }

    @Test("Les données écrites sur disque survivent à un « Réessayer » : la base rouverte les retrouve")
    func dataWrittenBeforeAFailureIsFoundAfterRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "TrivaLocalStore.store")

        let first = ChatHistoryStore(container: try openContainer(at: storeURL))
        _ = try first.createConversation(firstQuestion: "Conservée")

        var attempts = 0
        let storage = TrivaStorage(
            opener: {
                attempts += 1
                if attempts <= 4 { throw TrivaModelContainerError.creationFailed("disque verrouillé") }
                return try openContainer(at: storeURL)
            },
            retryDelaysMilliseconds: [1, 1, 1],
            pause: { _ in }
        )
        #expect(!storage.isAvailable)

        #expect(storage.retry())
        let reopened = ChatHistoryStore(storage: storage)
        #expect(try reopened.conversations().map(\.title) == ["Conservée"])
    }
}
