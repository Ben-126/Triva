//
//  SpotlightTestSupport.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : faux client Spotlight. Les tests ne touchent JAMAIS le vrai index de la machine
//  (l'app sert d'hôte aux tests : son index est celui de Triva, donc celui de l'utilisateur).
//

import Foundation
@testable import Triva

/// Classe verrouillée plutôt qu'`actor` : sous `-default-isolation=MainActor`, l'init synthétisé d'un acteur est
/// refusé par le compilateur, et les tests lisent ces compteurs de façon synchrone.
nonisolated final class FakeSpotlightClient: SpotlightIndexing, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _indexedBatches: [[SpotlightEntry]] = []
    private var _deletedBatches: [[UUID]] = []
    private var _deleteAllCount = 0
    private var _failsIndex = false
    private var _failsDeleteAll = false

    init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var indexedBatches: [[SpotlightEntry]] { locked { _indexedBatches } }
    var deletedBatches: [[UUID]] { locked { _deletedBatches } }
    var deleteAllCount: Int { locked { _deleteAllCount } }
    var indexCallCount: Int { locked { _indexedBatches.count } }
    var allIndexed: [SpotlightEntry] { locked { _indexedBatches.flatMap { $0 } } }
    var allDeleted: [UUID] { locked { _deletedBatches.flatMap { $0 } } }

    func setFailsIndex(_ value: Bool) { locked { _failsIndex = value } }
    func setFailsDeleteAll(_ value: Bool) { locked { _failsDeleteAll = value } }

    func index(_ entries: [SpotlightEntry]) async throws {
        try locked {
            if _failsIndex { throw Failure() }
            _indexedBatches.append(entries)
        }
    }

    func delete(ids: [UUID]) async throws {
        locked { _deletedBatches.append(ids) }
    }

    func deleteAll() async throws {
        try locked {
            if _failsDeleteAll { throw Failure() }
            _deleteAllCount += 1
        }
    }
}

/// Un historique factice : le contenu change d'un test à l'autre.
@MainActor
final class FakeSpotlightHistory {
    var entries: [SpotlightEntry] = []
    var fails = false
    private(set) var loadCount = 0

    func load() throws -> [SpotlightEntry] {
        loadCount += 1
        if fails { throw FakeSpotlightClient.Failure() }
        return entries
    }
}
