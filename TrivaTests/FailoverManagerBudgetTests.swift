//
//  FailoverManagerBudgetTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation
import Synchronization
import Testing
@testable import Triva

/// Client dont chaque appel échoue en « dépensant » 10 s sur l'horloge injectée (le délai d'une
/// instance muette), sans attendre pour de vrai.
nonisolated final class SlowFailingInstanceClient: SearXNGSearching, Sendable {
    private let clock: ReliabilityTestClock
    private let calls = Mutex<[URL]>([])

    init(clock: ReliabilityTestClock) {
        self.clock = clock
    }

    var calledInstances: [URL] { calls.withLock { $0 } }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calls.withLock { $0.append(instance) }
        clock.advance(10)
        throw URLError(.timedOut)
    }
}

/// Budget de temps d'une recherche SearXNG (mission E2d) : huit instances muettes de 10 s chacune
/// faisaient attendre plus d'une minute avant que la chaîne ne passe à Wikipédia.
@MainActor
@Suite("FailoverManager — budget de temps")
struct FailoverManagerBudgetTests {
    private let instances = (1...8).map { URL(string: "https://instance\($0).example")! }
    private let clock = ReliabilityTestClock()

    private func manager(
        client: SlowFailingInstanceClient,
        budget: TimeInterval,
        store: InstanceReliabilityStore = InstanceReliabilityStore()
    ) -> FailoverManager {
        let clock = clock
        return FailoverManager(client: client, instances: instances, reliability: store, now: { clock.now }, attemptBudget: budget)
    }

    @Test("Passé le budget, plus de nouvelle tentative : 3 instances de 10 s pour un budget de 30 s")
    func stopsOpeningAttemptsOnceTheBudgetIsSpent() async {
        let client = SlowFailingInstanceClient(clock: clock)

        let error = await #expect(throws: FailoverExhaustedError.self) {
            try await manager(client: client, budget: 30).searchDetailed(query: "q")
        }

        #expect(client.calledInstances.count == 3)
        #expect(error?.reasons == [.timeout, .timeout, .timeout])
    }

    @Test("Témoin : sans budget (infini), les huit instances sont essayées, c'est donc le budget qui coupe")
    func withoutABudgetEveryInstanceIsTried() async {
        let client = SlowFailingInstanceClient(clock: clock)

        await #expect(throws: FailoverExhaustedError.self) {
            try await manager(client: client, budget: .infinity).searchDetailed(query: "q")
        }

        #expect(client.calledInstances.count == 8)
    }

    @Test("Au moins une instance est toujours essayée, même avec un budget nul")
    func atLeastOneInstanceIsAlwaysTried() async {
        let client = SlowFailingInstanceClient(clock: clock)

        await #expect(throws: FailoverExhaustedError.self) {
            try await manager(client: client, budget: 0).searchDetailed(query: "q")
        }

        #expect(client.calledInstances.count == 1)
    }

    @Test("Les instances non essayées faute de temps ne sont pas notées comme fautives")
    func untriedInstancesAreNotRecordedAsFailures() async {
        let client = SlowFailingInstanceClient(clock: clock)
        let store = InstanceReliabilityStore()

        _ = try? await manager(client: client, budget: 30, store: store).searchDetailed(query: "q")

        let untried = Set(instances).subtracting(client.calledInstances)
        #expect(untried.count == 5)
        for instance in untried {
            #expect(store.tier(for: instance, at: clock.now) == .neutral)
        }
    }
}
