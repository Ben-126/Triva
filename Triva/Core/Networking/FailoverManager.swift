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

/// Variante détaillée de `FailoverError.allInstancesUnavailable`, levée par
/// `FailoverManager.searchDetailed` : elle garde le motif de chaque échec, pour qu'un adaptateur
/// (`SearXNGWebSearchProvider`) puisse dire « délai dépassé » plutôt qu'un vague « indisponible ».
/// `search(query:options:)` la ramène à `allInstancesUnavailable`, contrat inchangé pour les
/// appelants existants.
nonisolated struct FailoverExhaustedError: Error, Sendable, Equatable {
    /// Un motif par instance essayée, dans l'ordre des essais.
    let reasons: [InstanceFailureReason]
}

/// Essaie une liste d'instances SearXNG, en basculant sur la suivante dès qu'une échoue
/// (timeout, erreur HTTP, réponse non-JSON), dans l'ordre de FIABILITÉ MESURÉE.
///
/// Ordre d'essai d'une recherche :
/// 1. la dernière instance qui a répondu (cache : inutile de retester toute la liste à chaque
///    recherche), sauf si elle vient d'être mise de côté ;
/// 2. les autres par niveau de confiance (bonnes, neutres, médiocres), à égalité dans l'ordre de
///    la liste — voir `InstanceReliabilityStore.ordered` ;
/// 3. en dernier recours seulement, au plus `maxBenchedAttempts` instances mises de côté, la
///    plus proche de sa retentative d'abord. Sans ce filet, une coupure réseau de dix minutes
///    mettrait TOUTES les instances de côté et les recherches échoueraient immédiatement, même
///    réseau revenu.
///
/// Ce que ça apprend, et quand :
/// - chaque succès et chaque échec alimente `reliability` (latence, motif du dernier échec) ;
/// - si plusieurs instances échouent TOUTES par « aucune réponse réseau », l'appareil est
///   probablement hors ligne : ces échecs ne sont pas enregistrés, sinon une coupure de métro
///   ferait écarter de bonnes instances. Dès qu'une instance répond, les échecs précédents
///   sont enregistrés (le réseau fonctionne, ces instances-là sont vraiment en cause) ;
/// - une `Task` annulée n'est JAMAIS un échec d'instance (voir le commentaire dans la boucle).
actor FailoverManager {
    private let client: any SearXNGSearching
    /// Liste reçue, dans son ordre de priorité. Lecture seule, exposée (comme `reliability`)
    /// pour que l'assemblage de l'app et ses tests vérifient sur QUELLE liste et QUELLE
    /// mémoire un manager a été construit, sans lancer de recherche réseau.
    let instances: [URL]
    let reliability: InstanceReliabilityStore
    private let now: @Sendable () -> Date
    private let maxBenchedAttempts: Int
    private var cachedInstance: URL?

    /// - Parameters:
    ///   - reliability: mémoire de fiabilité. Par défaut un store EN MÉMOIRE, vide : les tests
    ///     et les aperçus n'écrivent jamais dans les vraies préférences. L'app, elle, passe le
    ///     store persisté et partagé (`InstanceReliabilityStore.shared`) par
    ///     `TrivaSharedStores.makeFailoverManager(instances:)` : un manager construit sans lui
    ///     repartirait d'une mémoire vide à chaque fois.
    ///   - now: horloge injectable, pour tester la mise de côté sans attendre.
    ///   - maxBenchedAttempts: nombre d'instances mises de côté tentées en dernier recours.
    init(
        client: any SearXNGSearching = SearXNGClient(),
        instances: [URL],
        reliability: InstanceReliabilityStore = InstanceReliabilityStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        maxBenchedAttempts: Int = 2
    ) {
        self.client = client
        self.instances = instances
        self.reliability = reliability
        self.now = now
        self.maxBenchedAttempts = max(0, maxBenchedAttempts)
    }

    func search(
        query: String,
        options: SearXNGSearchOptions = SearXNGSearchOptions()
    ) async throws -> SearXNGSearchResponse {
        do {
            return try await searchDetailed(query: query, options: options)
        } catch is FailoverExhaustedError {
            throw FailoverError.allInstancesUnavailable
        }
    }

    /// Comme `search`, mais lève `FailoverExhaustedError` (avec les motifs) au lieu de
    /// `FailoverError.allInstancesUnavailable`.
    func searchDetailed(
        query: String,
        options: SearXNGSearchOptions = SearXNGSearchOptions()
    ) async throws -> SearXNGSearchResponse {
        guard !instances.isEmpty else {
            throw FailoverError.noInstancesConfigured
        }

        var failures: [AttemptFailure] = []
        for instance in attemptOrder() {
            if Task.isCancelled {
                commit(failures, success: nil)
                throw CancellationError()
            }
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let response = try await client.search(query: query, options: options, instance: instance)
                commit(failures, success: (instance, start.duration(to: clock.now)))
                cachedInstance = instance
                return response
            } catch {
                // Une Task annulée pendant `client.search(...)` (ex. `URLError.cancelled`
                // propagé depuis `URLSession`) n'est PAS un vrai échec d'instance : la
                // rethrow immédiatement plutôt que de continuer à tester les instances
                // restantes (réseau/batterie gaspillés pour des recherches dont plus
                // personne n'a besoin), et surtout SANS toucher `cachedInstance` ni
                // enregistrer d'échec pour CETTE instance — son état réel n'a rien à voir
                // avec cette annulation.
                if Task.isCancelled {
                    commit(failures, success: nil)
                    throw error
                }
                failures.append(AttemptFailure(
                    instance: instance,
                    reason: InstanceFailureReason.classify(error),
                    date: now()
                ))
            }
        }

        cachedInstance = nil
        commit(failures, success: nil)
        throw FailoverExhaustedError(reasons: failures.map(\.reason))
    }

    /// Retente en tâche de fond les instances dont la mise de côté vient de se terminer, avec
    /// la sonde (une requête neutre « test », jamais celle de l'utilisateur), pour que leur
    /// retour en grâce ne dépende pas d'une vraie recherche qui paierait leur délai. Renvoie
    /// le nombre d'instances qui répondent de nouveau. À appeler hors du chemin d'une
    /// recherche (au lancement, au retour au premier plan) ; jamais bloquant pour l'utilisateur.
    @discardableResult
    func retestExpiredInstances(using prober: any InstanceProbing, limit: Int = 3) async -> Int {
        let date = now()
        let candidates = reliability.ordered(instances, at: date).active.filter {
            reliability.tier(for: $0, at: date) == .poor
        }
        let results = await InstanceProbeBatch.run(
            Array(candidates.prefix(max(0, limit))),
            using: prober,
            store: reliability
        )
        return results.values.filter(\.isHealthy).count
    }

    // MARK: Détails

    private struct AttemptFailure {
        let instance: URL
        let reason: InstanceFailureReason
        let date: Date
    }

    /// Ordre d'essai : cache, puis niveaux de confiance, puis dernier recours mis de côté.
    private func attemptOrder() -> [URL] {
        let ordering = reliability.ordered(instances, at: now())
        var active = ordering.active
        if let cachedInstance, let index = active.firstIndex(of: cachedInstance) {
            active.remove(at: index)
            active.insert(cachedInstance, at: 0)
        }
        return active + ordering.benched.prefix(maxBenchedAttempts)
    }

    /// Enregistre les observations d'une recherche, en une fois, une fois son issue connue
    /// (voir l'en-tête pour la règle « hors ligne »).
    private func commit(_ failures: [AttemptFailure], success: (instance: URL, latency: Duration)?) {
        let looksOffline = success == nil && failures.count >= 2 && failures.allSatisfy { $0.reason == .network }
        if !looksOffline {
            for failure in failures {
                reliability.recordFailure(for: failure.instance, reason: failure.reason, at: failure.date)
            }
        }
        if let success {
            reliability.recordSuccess(for: success.instance, latency: success.latency, at: now())
        }
    }
}
