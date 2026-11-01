//
//  SearXNGReliabilityTestSupport.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation
import Synchronization
@testable import Triva

/// Horloge de test : le temps n'avance que quand le test le décide, pour vérifier la mise de
/// côté d'une instance sans attendre dix minutes réelles.
final class ReliabilityTestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Client SearXNG factice scénarisé par instance : chaque instance réussit, ou échoue avec
/// l'erreur indiquée. Journalise les appels, leurs options et leurs requêtes.
///
/// Classe + `Mutex` plutôt qu'`actor` : avec Xcode 27.1 / Swift 6.4, un `actor` interne de la
/// cible de tests (isolation MainActor par défaut) conforme à un protocole `nonisolated` reçoit
/// un `nonisolated` implicite que le compilateur refuse ensuite (« 'nonisolated' modifier cannot
/// be applied to this declaration »). L'API reste la même (`await` toléré par les appelants).
nonisolated final class ScriptedInstanceClient: SearXNGSearching, Sendable {
    private struct State {
        var failures: [URL: any Error]
        var calledInstances: [URL] = []
        var lastQuery: String?
        var lastOptions: SearXNGSearchOptions?
    }

    private let state: Mutex<State>
    private let response: SearXNGSearchResponse

    var calledInstances: [URL] { state.withLock { $0.calledInstances } }
    var lastQuery: String? { state.withLock { $0.lastQuery } }
    var lastOptions: SearXNGSearchOptions? { state.withLock { $0.lastOptions } }

    init(failures: [URL: any Error] = [:], response: SearXNGSearchResponse = ScriptedInstanceClient.sampleResponse(count: 1)) {
        self.state = Mutex(State(failures: failures))
        self.response = response
    }

    static func sampleResponse(count: Int) -> SearXNGSearchResponse {
        SearXNGSearchResponse(
            results: (0..<count).map { index in
                SearXNGSearchResult(
                    title: "Résultat \(index)",
                    url: "https://exemple.test/\(index)",
                    content: nil,
                    imgSrc: nil,
                    thumbnailSrc: nil,
                    thumbnail: nil,
                    author: nil,
                    iframeSrc: nil
                )
            },
            suggestions: ["suggestion"]
        )
    }

    func setFailures(_ newFailures: [URL: any Error]) {
        state.withLock { $0.failures = newFailures }
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        let failure: (any Error)? = state.withLock { current in
            current.calledInstances.append(instance)
            current.lastQuery = query
            current.lastOptions = options
            return current.failures[instance]
        }
        if let failure { throw failure }
        return response
    }
}

/// Sonde factice : verdict scénarisé par instance, avec mesure de la concurrence maximale.
/// Classe + `Mutex` pour la même raison que `ScriptedInstanceClient`.
nonisolated final class ScriptedProber: InstanceProbing, Sendable {
    private struct State {
        var probed: [URL] = []
        var running = 0
        var maxRunning = 0
    }

    private let healthy: Set<URL>
    private let state = Mutex(State())

    var probed: [URL] { state.withLock { $0.probed } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    init(healthy: Set<URL>) {
        self.healthy = healthy
    }

    func probe(_ instance: URL) async throws -> InstanceProbeResult {
        state.withLock { current in
            current.probed.append(instance)
            current.running += 1
            current.maxRunning = max(current.maxRunning, current.running)
        }
        // Laisse les autres sondes démarrer : sans suspension réelle, la concurrence mesurée
        // serait toujours 1. Le compteur est décrémenté même si la tâche est annulée.
        defer { state.withLock { $0.running -= 1 } }
        try await Task.sleep(for: .milliseconds(5))
        return healthy.contains(instance)
            ? InstanceProbeResult(verdict: .healthy(resultCount: 3), latency: .milliseconds(120))
            : InstanceProbeResult(verdict: .failed(.notJSON), latency: .milliseconds(80))
    }
}

/// `UserDefaults` isolé, à supprimer en fin de test.
func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: @Sendable () -> Void) {
    let name = "SearXNGReliabilityTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    nonisolated(unsafe) let captured = defaults
    return (defaults, { captured.removePersistentDomain(forName: name) })
}
