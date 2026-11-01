//
//  FailoverManagerReliabilityTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/10/2026.
//

import Testing
import Foundation
@testable import Triva

/// Client dont le PROCHAIN appel reste en vol jusqu'à `resolve(with:)` : pour annuler la `Task`
/// pendant qu'une instance précise est interrogée.
private actor HangingSearXNGClient: SearXNGSearching {
    private(set) var calledInstances: [URL] = []
    private var continuation: CheckedContinuation<SearXNGSearchResponse, any Error>?

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calledInstances.append(instance)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
@Suite("FailoverManager — fiabilité mesurée")
struct FailoverManagerReliabilityTests {
    private let one = URL(string: "https://instance1.example")!
    private let two = URL(string: "https://instance2.example")!
    private let three = URL(string: "https://instance3.example")!
    private let four = URL(string: "https://instance4.example")!
    private let clock = ReliabilityTestClock()

    private func makeManager(
        client: any SearXNGSearching,
        instances: [URL],
        store: InstanceReliabilityStore = InstanceReliabilityStore(),
        maxBenchedAttempts: Int = 2
    ) -> FailoverManager {
        let clock = clock
        return FailoverManager(
            client: client,
            instances: instances,
            reliability: store,
            now: { clock.now },
            maxBenchedAttempts: maxBenchedAttempts
        )
    }

    // MARK: Ordre

    @Test("Une instance déjà éprouvée est essayée avant les autres, même en fin de liste")
    func provenInstanceGoesFirst() async throws {
        let store = InstanceReliabilityStore()
        store.recordSuccess(for: three, latency: .milliseconds(300), at: clock.now)
        let client = ScriptedInstanceClient()
        let manager = makeManager(client: client, instances: [one, two, three], store: store)

        _ = try await manager.search(query: "test")

        #expect(await client.calledInstances == [three])
    }

    @Test("Une instance mise de côté est sautée tant que d'autres répondent")
    func benchedInstanceIsSkipped() async throws {
        let store = InstanceReliabilityStore()
        store.recordFailure(for: one, reason: .notJSON, at: clock.now)
        store.recordFailure(for: one, reason: .notJSON, at: clock.now)
        let client = ScriptedInstanceClient()
        let manager = makeManager(client: client, instances: [one, two], store: store)

        _ = try await manager.search(query: "test")

        #expect(await client.calledInstances == [two])
    }

    @Test("Une instance médiocre dont la mise de côté est finie passe après les autres")
    func expiredBenchedInstanceGoesLast() async throws {
        let store = InstanceReliabilityStore()
        store.recordFailure(for: one, reason: .timeout, at: clock.now)
        store.recordFailure(for: one, reason: .timeout, at: clock.now)
        clock.advance(700)
        let client = ScriptedInstanceClient(failures: [two: SearXNGClientError.timeout, three: SearXNGClientError.timeout])
        let manager = makeManager(client: client, instances: [one, two, three], store: store)

        _ = try await manager.search(query: "test")

        #expect(await client.calledInstances == [two, three, one])
    }

    @Test("Mise de côté puis retentative : l'instance revient quand son délai est écoulé et qu'elle répond de nouveau")
    func benchedInstanceIsRetriedAfterItsDelay() async throws {
        let client = ScriptedInstanceClient(failures: [one: SearXNGClientError.timeout])
        let store = InstanceReliabilityStore()
        let manager = makeManager(client: client, instances: [one, two], store: store)

        // A : one échoue, two répond (mis en cache).
        _ = try await manager.search(query: "A")
        // B : two (cache) échoue à son tour, one échoue encore -> one est mise de côté.
        await client.setFailures([one: SearXNGClientError.timeout, two: SearXNGClientError.timeout])
        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await manager.search(query: "B")
        }
        #expect(store.tier(for: one, at: clock.now) == .benched)

        // C : 10 s plus tard, two répond ; one, encore de côté, n'est PAS essayée.
        clock.advance(10)
        await client.setFailures([one: SearXNGClientError.timeout])
        let callsBeforeC = await client.calledInstances.count
        _ = try await manager.search(query: "C")
        let callsInC = await client.calledInstances.dropFirst(callsBeforeC)
        #expect(Array(callsInC) == [two])

        // D : le délai est écoulé, two retombe en panne, one est retentée et répond.
        clock.advance(700)
        await client.setFailures([two: SearXNGClientError.timeout])
        let callsBeforeD = await client.calledInstances.count
        _ = try await manager.search(query: "D")
        let callsInD = await client.calledInstances.dropFirst(callsBeforeD)
        #expect(Array(callsInD) == [two, one])
        #expect(store.tier(for: one, at: clock.now) == .neutral)
        #expect(store.record(for: one)?.consecutiveFailures == 0)
    }

    @Test("Dernier recours : quand tout échoue, au plus deux instances mises de côté sont tentées, la plus proche de sa retentative d'abord")
    func lastResortTriesAtMostTwoBenchedInstances() async {
        let store = InstanceReliabilityStore()
        let starts: [(URL, TimeInterval)] = [(one, 0), (two, 0), (three, -100), (four, 0)]
        for (instance, offset) in starts {
            for _ in 0..<2 {
                store.recordFailure(for: instance, reason: .timeout, at: clock.now.addingTimeInterval(offset))
            }
        }
        clock.advance(1)
        let allFailing = Dictionary(uniqueKeysWithValues: [one, two, three, four].map { ($0, SearXNGClientError.timeout as any Error) })
        let client = ScriptedInstanceClient(failures: allFailing)
        let manager = makeManager(client: client, instances: [one, two, three, four], store: store)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await manager.search(query: "test")
        }

        #expect(await client.calledInstances == [three, one])
    }

    @Test("Dernier recours qui réussit : l'instance mise de côté est réhabilitée")
    func lastResortSuccessRehabilitates() async throws {
        let store = InstanceReliabilityStore()
        store.recordFailure(for: one, reason: .timeout, at: clock.now)
        store.recordFailure(for: one, reason: .timeout, at: clock.now)
        let client = ScriptedInstanceClient()
        let manager = makeManager(client: client, instances: [one], store: store)

        _ = try await manager.search(query: "test")

        #expect(await client.calledInstances == [one])
        #expect(store.record(for: one)?.consecutiveFailures == 0)
        // 2 échecs + 1 succès : plus de série d'échecs, mais le taux (0,4) ne suffit pas à « bonne ».
        #expect(store.tier(for: one, at: clock.now) == .neutral)
    }

    @Test("Une adresse en double dans la liste n'est essayée qu'une fois")
    func duplicateInstancesAreTriedOnce() async {
        let client = ScriptedInstanceClient(failures: [one: SearXNGClientError.timeout, two: SearXNGClientError.timeout])
        let manager = makeManager(client: client, instances: [one, URL(string: "https://INSTANCE1.example/")!, two])

        _ = try? await manager.search(query: "test")

        #expect(await client.calledInstances == [one, two])
    }

    // MARK: Apprentissage

    @Test("Les échecs sont enregistrés avec leur motif, le succès avec sa latence")
    func recordsReasonsAndLatency() async throws {
        let store = InstanceReliabilityStore()
        let client = ScriptedInstanceClient(failures: [one: SearXNGClientError.requestFailed(statusCode: 403)])
        let manager = makeManager(client: client, instances: [one, two], store: store)

        _ = try await manager.search(query: "test")

        let failed = try #require(store.record(for: one))
        #expect(failed.lastFailureReason == .accessDenied)
        #expect(failed.failures == 1)
        let succeeded = try #require(store.record(for: two))
        #expect(succeeded.successes == 1)
        #expect(succeeded.averageLatencyMilliseconds != nil)
    }

    @Test("Appareil probablement hors ligne : plusieurs échecs réseau sans aucune réponse ne sont PAS enregistrés")
    func offlineFailuresAreNotRecorded() async {
        let store = InstanceReliabilityStore()
        let offline: [URL: any Error] = [
            one: SearXNGClientError.transportError,
            two: SearXNGClientError.transportError,
            three: SearXNGClientError.transportError,
        ]
        let manager = makeManager(client: ScriptedInstanceClient(failures: offline), instances: [one, two, three], store: store)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await manager.search(query: "test")
        }

        #expect(store.record(for: one) == nil)
        #expect(store.record(for: two) == nil)
        #expect(store.record(for: three) == nil)
    }

    @Test("Si une instance répond, les échecs réseau précédents sont bien imputés aux instances")
    func networkFailuresAreRecordedWhenAnotherInstanceAnswers() async throws {
        let store = InstanceReliabilityStore()
        let failures: [URL: any Error] = [one: SearXNGClientError.transportError, two: SearXNGClientError.transportError]
        let manager = makeManager(client: ScriptedInstanceClient(failures: failures), instances: [one, two, three], store: store)

        _ = try await manager.search(query: "test")

        #expect(store.record(for: one)?.lastFailureReason == .network)
        #expect(store.record(for: two)?.lastFailureReason == .network)
    }

    @Test("Un échec réseau unique (une seule instance) est enregistré")
    func singleNetworkFailureIsRecorded() async {
        let store = InstanceReliabilityStore()
        let client = ScriptedInstanceClient(failures: [one: SearXNGClientError.transportError])
        let manager = makeManager(client: client, instances: [one], store: store)

        _ = try? await manager.search(query: "test")

        #expect(store.record(for: one)?.failures == 1)
    }

    @Test("Une annulation en vol n'est PAS enregistrée comme un échec de l'instance")
    func cancellationIsNotRecordedAsFailure() async {
        let store = InstanceReliabilityStore()
        let client = HangingSearXNGClient()
        let manager = makeManager(client: client, instances: [one, two], store: store)

        let task = Task { try await manager.search(query: "test") }
        var attempts = 0
        while await client.calledInstances.isEmpty, attempts < 500 {
            // `Task.sleep` et non `Task.yield()` : voir le piège documenté dans CLAUDE.md.
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        task.cancel()
        await client.resolve(with: SearXNGClientError.transportError)
        let result = await task.result

        #expect(throws: (any Error).self) { try result.get() }
        #expect(await client.calledInstances == [one])
        #expect(store.record(for: one) == nil)
    }

    @Test("La mesure persistée est réutilisée par un nouveau FailoverManager")
    func learningSurvivesANewManager() async throws {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }
        let firstClient = ScriptedInstanceClient(failures: [one: SearXNGClientError.timeout, two: SearXNGClientError.timeout])
        let first = makeManager(
            client: firstClient,
            instances: [one, two, three],
            store: InstanceReliabilityStore(userDefaults: defaults)
        )
        _ = try await first.search(query: "premier lancement")

        let secondClient = ScriptedInstanceClient()
        let second = makeManager(
            client: secondClient,
            instances: [one, two, three],
            store: InstanceReliabilityStore(userDefaults: defaults)
        )
        _ = try await second.search(query: "second lancement")

        // Au second lancement, three (la seule qui a répondu) passe devant one et two.
        #expect(await secondClient.calledInstances == [three])
    }

    // MARK: Erreurs détaillées

    @Test("searchDetailed garde le motif de chaque instance, search retombe sur allInstancesUnavailable")
    func detailedErrorKeepsReasons() async {
        let failures: [URL: any Error] = [
            one: SearXNGClientError.timeout,
            two: SearXNGClientError.requestFailed(statusCode: 429),
        ]
        let manager = makeManager(client: ScriptedInstanceClient(failures: failures), instances: [one, two])

        await #expect(throws: FailoverExhaustedError(reasons: [.timeout, .rateLimited])) {
            _ = try await manager.searchDetailed(query: "test")
        }
        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await manager.search(query: "test")
        }
    }

    // MARK: Retentative en tâche de fond

    @Test("retestExpiredInstances sonde les instances médiocres (délai écoulé), pas celles encore de côté")
    func retestsOnlyExpiredInstances() async {
        let store = InstanceReliabilityStore()
        for _ in 0..<2 { store.recordFailure(for: one, reason: .timeout, at: clock.now) }
        clock.advance(700)
        for _ in 0..<2 { store.recordFailure(for: two, reason: .timeout, at: clock.now) }
        let prober = ScriptedProber(healthy: [one, two, three])
        let manager = makeManager(client: ScriptedInstanceClient(), instances: [one, two, three], store: store)

        let recovered = await manager.retestExpiredInstances(using: prober)

        #expect(await prober.probed == [one])
        #expect(recovered == 1)
        #expect(store.record(for: one)?.consecutiveFailures == 0)
        #expect(store.tier(for: two, at: clock.now) == .benched)
    }
}
