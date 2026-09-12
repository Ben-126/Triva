//
//  FailoverManager.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

enum FailoverError: Error, Sendable, Equatable {
    case noInstancesConfigured
    case allInstancesUnavailable
}

/// Essaie une liste d'instances SearXNG dans l'ordre, en basculant sur la
/// suivante dès qu'une échoue (timeout, erreur HTTP, réponse non-JSON).
/// Garde en cache la dernière instance qui a fonctionné pour l'essayer en
/// premier la prochaine fois, plutôt que de retester toute la liste à chaque
/// recherche.
actor FailoverManager {
    private let client: any SearXNGSearching
    private let instances: [URL]
    private var cachedInstance: URL?

    init(client: any SearXNGSearching = SearXNGClient(), instances: [URL]) {
        self.client = client
        self.instances = instances
    }

    func search(
        query: String,
        options: SearXNGSearchOptions = SearXNGSearchOptions()
    ) async throws -> SearXNGSearchResponse {
        guard !instances.isEmpty else {
            throw FailoverError.noInstancesConfigured
        }

        for instance in orderedByCache() {
            try Task.checkCancellation()
            do {
                let response = try await client.search(query: query, options: options, instance: instance)
                cachedInstance = instance
                return response
            } catch {
                // Une Task annulée pendant `client.search(...)` (ex.
                // `URLError.cancelled` propagé depuis `URLSession`) n'est PAS
                // un vrai échec d'instance : la rethrow immédiatement plutôt
                // que de continuer à tester les instances restantes (réseau/
                // batterie gaspillés pour des recherches dont plus personne
                // n'a besoin), et surtout SANS toucher `cachedInstance` — la
                // dernière instance connue pour fonctionner reste valable,
                // cette annulation n'a rien à voir avec sa disponibilité
                // réelle.
                if Task.isCancelled {
                    throw error
                }
                continue
            }
        }

        cachedInstance = nil
        throw FailoverError.allInstancesUnavailable
    }

    private func orderedByCache() -> [URL] {
        guard let cachedInstance, let index = instances.firstIndex(of: cachedInstance) else {
            return instances
        }
        var ordered = instances
        ordered.remove(at: index)
        ordered.insert(cachedInstance, at: 0)
        return ordered
    }
}
