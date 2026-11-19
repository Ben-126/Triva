//
//  MLXProviderPoolTests+Doubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/11/2026.
//

import Foundation
import Synchronization
@testable import Triva

/// Journal partagé des événements de plusieurs doubles (ordre chargement / déchargement / génération).
actor PoolEventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Porte que le test ouvre quand il veut : tant qu'elle est fermée, `wait()` suspend.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// Compteurs du double, protégés par un verrou (lus et écrits depuis plusieurs tâches).
struct FakeLocalModelCounters {
    var loadCount = 0
    var unloadCount = 0
    var isLoaded = false
    var activeGenerations = 0
    var maxConcurrentGenerations = 0
    var startedGenerations = 0
}

/// Double de `MLXProvider` pour le pool : compte chargements, déchargements et générations
/// simultanées, et peut bloquer chargement ou génération derrière une porte. Classe + `Mutex`
/// (et non acteur) : un acteur du module de test ne peut pas se conformer à `AIGenerating`,
/// protocole isolé au main actor par le réglage d'isolation par défaut de l'app.
final class FakeLocalModel: PoolableLocalModel, Sendable {
    let name: String
    private let log: PoolEventLog
    private let loadGate: TestGate?
    private let generationGate: TestGate?
    private let loadError: MLXProviderError?
    private let state = Mutex(FakeLocalModelCounters())

    init(
        name: String,
        log: PoolEventLog = PoolEventLog(),
        loadGate: TestGate? = nil,
        generationGate: TestGate? = nil,
        loadError: MLXProviderError? = nil
    ) {
        self.name = name
        self.log = log
        self.loadGate = loadGate
        self.generationGate = generationGate
        self.loadError = loadError
    }

    var counters: FakeLocalModelCounters { state.withLock { $0 } }
    var loadCount: Int { counters.loadCount }
    var unloadCount: Int { counters.unloadCount }
    var startedGenerations: Int { counters.startedGenerations }
    var maxConcurrentGenerations: Int { counters.maxConcurrentGenerations }

    func loadIntoMemory() async throws {
        await log.record("load \(name) start")
        await loadGate?.wait()
        state.withLock { $0.loadCount += 1 }
        if let loadError { throw loadError }
        state.withLock { $0.isLoaded = true }
        await log.record("load \(name) end")
    }

    func unloadFromMemory() async {
        state.withLock {
            $0.unloadCount += 1
            $0.isLoaded = false
        }
        await log.record("unload \(name)")
    }

    func generate(prompt: String) async throws -> String {
        let started = state.withLock { counters -> Bool in
            guard counters.isLoaded else { return false }
            counters.startedGenerations += 1
            counters.activeGenerations += 1
            counters.maxConcurrentGenerations = max(counters.maxConcurrentGenerations, counters.activeGenerations)
            return true
        }
        guard started else { throw MLXProviderError.modelNotLoaded }
        await log.record("generate \(name) \(prompt) start")
        await generationGate?.wait()
        state.withLock { $0.activeGenerations -= 1 }
        await log.record("generate \(name) \(prompt) end")
        return "\(name):\(prompt)"
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await self.generate(prompt: prompt)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Attente coopérative bornée (`Task.sleep`, jamais `Task.yield()` seul : voir CLAUDE.md).
@MainActor
func waitForPool(
    timeout: Duration = .seconds(10),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
func makePoolSelection(selected modelID: String?) -> MLXModelSelectionStore {
    let defaults = UserDefaults(suiteName: "MLXProviderPoolTests-\(UUID().uuidString)")!
    let store = MLXModelSelectionStore(userDefaults: defaults)
    store.selectedModelID = modelID
    return store
}

/// Compte les instances fabriquées par le pool (`make`), lu par le test sur le main actor.
@MainActor
final class MakeCounter {
    private(set) var count = 0

    func make(_ model: any PoolableLocalModel) -> any PoolableLocalModel {
        count += 1
        return model
    }
}
