//
//  SpotlightIndexer.swift
//  Triva
//
//  Chantier 2.1 (mission F) : tient l'index Spotlight à jour (titres et dates des conversations, jamais le texte).
//
//  - À chaque changement d'historique : une passe, 2 s après le dernier changement (un échange qui écrit plusieurs
//    fois de suite n'en provoque qu'une).
//  - Seules les différences partent à Spotlight (`SpotlightIndexPlan`). Sur disque (réglages de l'app) : les
//    identifiants indexés, rien d'autre (aucun titre) ; en mémoire : le dernier état envoyé.
//  - Réglage éteint : tout l'index est retiré et rien n'est plus envoyé. « Tout effacer » : idem, même réglage éteint.
//  - Une passe est unique à la fois : un changement arrivé pendant une passe en provoque une seconde juste après.
//

import Foundation
import OSLog

@MainActor
final class SpotlightIndexer {
    /// Identifiants (UUID en texte) des conversations indexées, dans les réglages de l'app.
    static let indexedIDsKey = "system.spotlight.indexedIDs"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "Spotlight"
    )

    private let client: any SpotlightIndexing
    private let preferences: SystemIntegrationPreferences
    private let defaults: UserDefaults
    private let delay: Duration
    /// Attente avant un nouvel essai de retrait refusé par Spotlight (doublée à chaque essai).
    private let purgeRetryDelay: Duration
    private let loadEntries: @MainActor () throws -> [SpotlightEntry]

    /// Ce qui a été envoyé pendant CE lancement ; `nil` : la prochaine passe envoie tout.
    private var previous: [UUID: SpotlightEntry]?
    private var debounce: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var syncAgain = false
    private var purgeRetry: Task<Void, Never>?

    /// Essais de retrait au plus après un refus de Spotlight, avant d'attendre le prochain lancement ou la prochaine bascule.
    static let maxPurgeRetries = 3

    /// - Parameters:
    ///   - delay: attente après le dernier changement (2 s dans l'app, nulle dans les tests).
    ///   - loadEntries: l'historique, les plus récentes d'abord. Elle LÈVE quand l'historique n'est pas lisible :
    ///     jamais une liste vide par défaut, qui ferait tout retirer de l'index.
    init(
        client: any SpotlightIndexing,
        preferences: SystemIntegrationPreferences,
        defaults: UserDefaults,
        delay: Duration = .seconds(2),
        purgeRetryDelay: Duration = .seconds(30),
        loadEntries: @escaping @MainActor () throws -> [SpotlightEntry]
    ) {
        self.client = client
        self.preferences = preferences
        self.defaults = defaults
        self.delay = delay
        self.purgeRetryDelay = purgeRetryDelay
        self.loadEntries = loadEntries
    }

    /// Les identifiants que l'app a donnés à Spotlight (gardés sur disque, pour retirer ce qui a disparu même après
    /// un redémarrage).
    var indexedIDs: Set<UUID> {
        Set((defaults.stringArray(forKey: Self.indexedIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    // MARK: Passes

    /// Demande une passe, 2 s après le dernier appel. Sans effet si le réglage est éteint.
    func scheduleSync() {
        guard preferences.isSpotlightEnabled else { return }
        if running != nil {
            syncAgain = true
            return
        }
        debounce?.cancel()
        let delay = delay
        debounce = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.startRunIfNeeded()
        }
    }

    /// Fait une passe tout de suite et attend sa fin (la passe en cours, si une tourne, puis celle qu'elle a fait
    /// redemander).
    func syncNow() async {
        debounce?.cancel()
        debounce = nil
        guard preferences.isSpotlightEnabled else { return }
        startRunIfNeeded()
        await running?.value
    }

    /// Le réglage vient de changer (ou l'app démarre) : allumé, tout est (ré)indexé ; éteint, l'index est vidé.
    func settingChanged() async {
        if preferences.isSpotlightEnabled {
            cancelPurgeRetry()
            scheduleSync()
        } else {
            await purgeIfNeeded()
        }
    }

    /// Le système demande de reconstruire l'index (`IndexedEntityQuery.reindexAllEntities`).
    func reindexAll() async {
        guard preferences.isSpotlightEnabled else { return }
        previous = nil
        await syncNow()
    }

    /// « Tout effacer » : l'index est vidé, que le réglage soit allumé ou non. `false` si Spotlight a refusé : les
    /// identifiants restent alors, pour réessayer.
    func eraseAll() async -> Bool {
        cancelPurgeRetry()
        stopPending()
        await running?.value
        do {
            try await client.deleteAll()
        } catch {
            Self.logger.error("Spotlight : « Tout effacer » a échoué : \(String(describing: error), privacy: .private)")
            return false
        }
        saveIDs([])
        previous = nil
        return true
    }

    // MARK: Interne

    private func stopPending() {
        debounce?.cancel()
        debounce = nil
        syncAgain = false
    }

    private func startRunIfNeeded() {
        guard running == nil else {
            syncAgain = true
            return
        }
        running = Task { [weak self] in
            guard let self else { return }
            repeat {
                syncAgain = false
                await syncOnce()
            } while syncAgain && preferences.isSpotlightEnabled
            running = nil
        }
    }

    private func purgeIfNeeded(attempt: Int = 0) async {
        stopPending()
        await running?.value
        guard !indexedIDs.isEmpty || previous != nil else { return }
        do {
            try await client.deleteAll()
        } catch {
            // Les identifiants restent. L'écran promet « tout de suite » : on réessaie de nous-mêmes, quelques fois,
            // sans attendre une prochaine bascule ou un prochain lancement.
            Self.logger.error("Spotlight : retrait de l'index impossible : \(String(describing: error), privacy: .private)")
            scheduleRetry(after: attempt)
            return
        }
        saveIDs([])
        previous = nil
    }

    private func scheduleRetry(after attempt: Int) {
        guard attempt < Self.maxPurgeRetries else { return }
        purgeRetry?.cancel()
        let wait = purgeRetryDelay * (1 << attempt)
        purgeRetry = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self, !self.preferences.isSpotlightEnabled else { return }
            await self.purgeIfNeeded(attempt: attempt + 1)
        }
    }

    private func cancelPurgeRetry() {
        purgeRetry?.cancel()
        purgeRetry = nil
    }

    /// Attend la fin d'un éventuel nouvel essai de retrait (tests).
    func settlePurgeRetries() async {
        while let current = purgeRetry {
            await current.value
            if purgeRetry == current { purgeRetry = nil }
        }
    }

    private func syncOnce() async {
        guard preferences.isSpotlightEnabled else { return }
        let desired: [SpotlightEntry]
        do {
            desired = try loadEntries()
        } catch {
            Self.logger.error("Spotlight : historique illisible, index laissé tel quel : \(String(describing: error), privacy: .private)")
            return
        }
        let wanted = SpotlightIndexPlan.capped(desired)
        let known = indexedIDs
        let plan = SpotlightIndexPlan.make(desired: wanted, previous: previous, indexedIDs: known)

        if !plan.toIndex.isEmpty {
            // On note d'abord (plus large) : un envoi interrompu ne laisse jamais d'élément inconnu dans l'index.
            saveIDs(known.union(plan.toIndex.map(\.id)))
            do {
                try await client.index(plan.toIndex)
            } catch {
                Self.logger.error("Spotlight : indexation impossible : \(String(describing: error), privacy: .private)")
                return
            }
        }
        if !plan.toDelete.isEmpty {
            do {
                try await client.delete(ids: plan.toDelete)
            } catch {
                Self.logger.error("Spotlight : retrait impossible : \(String(describing: error), privacy: .private)")
                return
            }
        }
        saveIDs(known.union(plan.toIndex.map(\.id)).subtracting(plan.toDelete))
        previous = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0) })
    }

    private func saveIDs(_ ids: Set<UUID>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.indexedIDsKey)
        } else {
            defaults.set(ids.map(\.uuidString).sorted(), forKey: Self.indexedIDsKey)
        }
    }
}
