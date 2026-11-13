//
//  GateClock.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation
import Synchronization

/// Horloge de test dont les `sleep` ne se terminent PAS avec le temps mais quand le test ouvre la
/// porte (`open()`), ou quand la tâche est annulée (comme une vraie horloge). Les tests de délais
/// (échéance d'un tour de scrape, délai de grâce des médias) n'ont ainsi plus de durée réelle à
/// deviner : sous charge, 200 ms ou 20 ms pouvaient expirer avant l'événement qu'ils attendaient.
///
/// `now` est celui d'une vraie `ContinuousClock` : seul le sommeil est piloté. `sleeperCount` dit
/// combien de `sleep` ont démarré, pour que le test attende cet événement avant d'ouvrir.
nonisolated final class GateClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant

    private struct State {
        var isOpen = false
        var nextID = 0
        var sleepers = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        var cancelledBeforeStored: Set<Int> = []
    }

    private enum Action { case resume, cancel, store }

    private let state = Mutex(State())

    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .nanoseconds(1) }

    /// Nombre de `sleep` démarrés depuis la création.
    var sleeperCount: Int { state.withLock { $0.sleepers } }

    /// Réveille tous les `sleep` en cours et ceux qui suivront.
    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.sleepers += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let action = state.withLock { state -> Action in
                    if state.cancelledBeforeStored.remove(id) != nil { return .cancel }
                    if state.isOpen { return .resume }
                    state.waiters[id] = continuation
                    return .store
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .store: break
                }
            }
        } onCancel: {
            let stored = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let stored = state.waiters.removeValue(forKey: id) { return stored }
                state.cancelledBeforeStored.insert(id)
                return nil
            }
            stored?.resume(throwing: CancellationError())
        }
    }
}
