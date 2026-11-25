//
//  SpotlightIndexClient.swift
//  Triva
//
//  Chantier 2.1 (mission F) : le seul endroit qui parle à Core Spotlight. Un protocole pour que les tests ne touchent
//  JAMAIS le vrai index de la machine.
//

import AppIntents
import CoreSpotlight
import Foundation

nonisolated protocol SpotlightIndexing: Sendable {
    func index(_ entries: [SpotlightEntry]) async throws
    func delete(ids: [UUID]) async throws
    func deleteAll() async throws
}

/// L'index réel de l'app (`CSSearchableIndex.default()`), pour les `ConversationEntity` : titre et date, rien d'autre.
nonisolated struct CoreSpotlightIndexClient: SpotlightIndexing {
    /// Envois par lots : 500 conversations d'un coup ne gagnent rien.
    static let batchSize = 100

    func index(_ entries: [SpotlightEntry]) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()
        for start in stride(from: 0, to: entries.count, by: Self.batchSize) {
            let batch = entries[start..<min(start + Self.batchSize, entries.count)]
            let entities = batch.map { ConversationEntity(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
            try await index.indexAppEntities(entities)
        }
    }

    func delete(ids: [UUID]) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
            try await index.deleteAppEntities(identifiedBy: batch, ofType: ConversationEntity.self)
        }
    }

    func deleteAll() async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        try await CSSearchableIndex.default().deleteAppEntities(ofType: ConversationEntity.self)
    }
}
