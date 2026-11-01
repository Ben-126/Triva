//
//  SearXNGReliabilityTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/10/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Motifs d'échec

@MainActor
@Suite("InstanceFailureReason — classification")
struct InstanceFailureReasonTests {
    @Test("Les erreurs du client SearXNG sont rangées dans le bon motif", arguments: [
        (SearXNGClientError.timeout, InstanceFailureReason.timeout),
        (SearXNGClientError.transportError, .network),
        (SearXNGClientError.decodingFailed, .notJSON),
        (SearXNGClientError.invalidURL, .invalidAddress),
        (SearXNGClientError.requestFailed(statusCode: 403), .accessDenied),
        (SearXNGClientError.requestFailed(statusCode: 429), .rateLimited),
        (SearXNGClientError.requestFailed(statusCode: 503), .serverError),
        (SearXNGClientError.requestFailed(statusCode: 404), .httpError),
    ])
    func classifiesClientErrors(error: SearXNGClientError, expected: InstanceFailureReason) {
        #expect(InstanceFailureReason.classify(error) == expected)
    }

    @Test("Une URLError de délai est un timeout, toute autre est un échec réseau")
    func classifiesURLErrors() {
        #expect(InstanceFailureReason.classify(URLError(.timedOut)) == .timeout)
        #expect(InstanceFailureReason.classify(URLError(.notConnectedToInternet)) == .network)
    }

    @Test("Une erreur inconnue est rangée en unknown, sans planter")
    func classifiesUnknownErrors() {
        struct Strange: Error {}
        #expect(InstanceFailureReason.classify(Strange()) == .unknown)
    }

    @Test("Un blocage de configuration est retenté moins vite qu'une panne transitoire")
    func blockingReasonsBackOffLonger() {
        #expect(InstanceFailureReason.accessDenied.baseBackoff > InstanceFailureReason.rateLimited.baseBackoff)
        #expect(InstanceFailureReason.rateLimited.baseBackoff > InstanceFailureReason.timeout.baseBackoff)
        #expect(InstanceFailureReason.notJSON.baseBackoff == InstanceFailureReason.accessDenied.baseBackoff)
    }

    @Test("Chaque motif a un libellé non vide")
    func everyReasonHasAMessage() {
        for reason in InstanceFailureReason.allCases {
            #expect(!reason.userFacingMessage.isEmpty)
        }
    }
}

// MARK: - Fiche d'une instance et niveaux

@MainActor
@Suite("InstanceReliabilityRecord — niveaux")
struct InstanceReliabilityRecordTests {
    private let policy = InstanceReliabilityPolicy.standard
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func successRecord(latency: Double? = 500) -> InstanceReliabilityRecord {
        InstanceReliabilityRecord().recordingSuccess(latencyMilliseconds: latency, at: t0, policy: policy)
    }

    @Test("Une instance jamais vue est neutre, taux lissé à 0,5")
    func unknownIsNeutral() {
        let record = InstanceReliabilityRecord()
        #expect(record.tier(at: t0, policy: policy) == .neutral)
        #expect(record.successRate == 0.5)
    }

    @Test("Un succès rapide suffit à rendre une instance bonne")
    func oneFastSuccessIsGood() {
        #expect(successRecord().tier(at: t0, policy: policy) == .good)
    }

    @Test("Une instance qui répond mais lentement est rétrogradée en neutre")
    func slowSuccessIsNeutral() {
        #expect(successRecord(latency: 6_000).tier(at: t0, policy: policy) == .neutral)
        #expect(successRecord(latency: 4_000).tier(at: t0, policy: policy) == .good)
    }

    @Test("Un échec isolé ne change pas le niveau : trop peu de preuves")
    func singleFailureStaysNeutral() {
        let record = InstanceReliabilityRecord()
            .recordingFailure(reason: .timeout, at: t0, policy: policy)
        #expect(record.tier(at: t0, policy: policy) == .neutral)
        #expect(record.benchedUntil(policy: policy) == nil)
    }

    @Test("Un échec après un succès repasse l'instance en neutre")
    func failureAfterSuccessIsNeutral() {
        let record = successRecord().recordingFailure(reason: .timeout, at: t0, policy: policy)
        #expect(record.tier(at: t0, policy: policy) == .neutral)
    }

    @Test("Deux échecs de suite mettent l'instance de côté, jusqu'à la fin du délai du motif")
    func twoFailuresBenchTheInstance() {
        let record = InstanceReliabilityRecord()
            .recordingFailure(reason: .timeout, at: t0, policy: policy)
            .recordingFailure(reason: .timeout, at: t0, policy: policy)
        #expect(record.tier(at: t0.addingTimeInterval(1), policy: policy) == .benched)
        #expect(record.benchedUntil(policy: policy) == t0.addingTimeInterval(600))
    }

    @Test("Le délai écoulé, l'instance est retentable mais passe après les autres (médiocre)")
    func expiredBenchBecomesPoor() {
        let record = InstanceReliabilityRecord()
            .recordingFailure(reason: .timeout, at: t0, policy: policy)
            .recordingFailure(reason: .timeout, at: t0, policy: policy)
        #expect(record.tier(at: t0.addingTimeInterval(601), policy: policy) == .poor)
    }

    @Test("Un succès efface la série d'échecs et la mise de côté")
    func successResetsStreak() {
        let record = InstanceReliabilityRecord()
            .recordingFailure(reason: .notJSON, at: t0, policy: policy)
            .recordingFailure(reason: .notJSON, at: t0, policy: policy)
            .recordingSuccess(latencyMilliseconds: 300, at: t0.addingTimeInterval(5), policy: policy)
        #expect(record.consecutiveFailures == 0)
        #expect(record.benchedUntil(policy: policy) == nil)
        #expect(record.tier(at: t0.addingTimeInterval(5), policy: policy) == .neutral)
    }

    @Test("Un taux de réussite bas sur assez d'essais classe l'instance médiocre")
    func lowRateWithEnoughSamplesIsPoor() {
        let record = InstanceReliabilityRecord(successes: 1, failures: 4, consecutiveFailures: 1)
        #expect(record.tier(at: t0, policy: policy) == .poor)
        let fewSamples = InstanceReliabilityRecord(successes: 0, failures: 3, consecutiveFailures: 1)
        #expect(fewSamples.tier(at: t0, policy: policy) == .neutral)
    }

    @Test("Le délai de mise de côté double à chaque échec au-delà du seuil, puis plafonne à 24 h")
    func backoffGrowsAndCaps() {
        #expect(policy.backoff(for: .timeout, consecutiveFailures: 2) == 600)
        #expect(policy.backoff(for: .timeout, consecutiveFailures: 3) == 1_200)
        #expect(policy.backoff(for: .timeout, consecutiveFailures: 4) == 2_400)
        #expect(policy.backoff(for: .accessDenied, consecutiveFailures: 2) == 3_600)
        #expect(policy.backoff(for: .accessDenied, consecutiveFailures: 7) == 86_400)
        #expect(policy.backoff(for: .accessDenied, consecutiveFailures: 10_000) == 86_400)
    }

    @Test("La latence moyenne est une moyenne mobile exponentielle")
    func latencyIsSmoothed() throws {
        let record = successRecord(latency: 1_000)
            .recordingSuccess(latencyMilliseconds: 2_000, at: t0, policy: policy)
        let average = try #require(record.averageLatencyMilliseconds)
        // 1000 + 0,3 * (2000 - 1000)
        #expect(abs(average - 1_300) < 0.001)
    }

    @Test("Les compteurs sont repliés au-delà de la fenêtre, sans jamais perdre un échec")
    func windowFoldsCountersButKeepsFailures() {
        var record = InstanceReliabilityRecord().recordingFailure(reason: .timeout, at: t0, policy: policy)
        for _ in 0..<60 {
            record = record.recordingSuccess(latencyMilliseconds: 100, at: t0, policy: policy)
        }
        #expect(record.successes + record.failures <= policy.window)
        #expect(record.failures >= 1)
    }
}

// MARK: - Store : classement et persistance

@MainActor
@Suite("InstanceReliabilityStore")
struct InstanceReliabilityStoreTests {
    private let a = URL(string: "https://a.example")!
    private let b = URL(string: "https://b.example")!
    private let c = URL(string: "https://c.example")!
    private let d = URL(string: "https://d.example")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Classement : bonnes d'abord, puis neutres, puis médiocres, ordre de la liste à égalité")
    func ordersByTierThenListOrder() {
        let store = InstanceReliabilityStore()
        // a : inconnue (neutre) ; b : bonne ; c : médiocre (retentable) ; d : neutre
        store.recordSuccess(for: b, latency: .milliseconds(200), at: t0)
        store.recordFailure(for: c, reason: .timeout, at: t0)
        store.recordFailure(for: c, reason: .timeout, at: t0)

        let ordering = store.ordered([a, b, c, d], at: t0.addingTimeInterval(700))

        #expect(ordering.active == [b, a, d, c])
        #expect(ordering.benched.isEmpty)
    }

    @Test("L'ordre de la liste prime sur la latence : une instance prioritaire plus lente reste devant")
    func listOrderBeatsLatencyWithinTier() {
        let store = InstanceReliabilityStore()
        store.recordSuccess(for: a, latency: .milliseconds(900), at: t0)
        store.recordSuccess(for: b, latency: .milliseconds(100), at: t0)

        #expect(store.ordered([a, b], at: t0).active == [a, b])
    }

    @Test("Les instances mises de côté sont à part, la plus proche de sa retentative en premier")
    func benchedAreSeparatedAndSortedByExpiry() {
        let store = InstanceReliabilityStore()
        // a et c écartées pour 600 s, mais c a échoué plus tôt : elle sera retentée avant.
        store.recordFailure(for: a, reason: .timeout, at: t0)
        store.recordFailure(for: a, reason: .timeout, at: t0)
        store.recordFailure(for: c, reason: .timeout, at: t0.addingTimeInterval(-100))
        store.recordFailure(for: c, reason: .timeout, at: t0.addingTimeInterval(-100))

        let ordering = store.ordered([a, b, c], at: t0.addingTimeInterval(1))

        #expect(ordering.active == [b])
        #expect(ordering.benched == [c, a])
        #expect(store.benchedUntil(for: a, at: t0.addingTimeInterval(1)) == t0.addingTimeInterval(600))
        #expect(store.benchedUntil(for: b, at: t0.addingTimeInterval(1)) == nil)
    }

    @Test("Deux écritures de la même instance (casse, barre finale) ne forment qu'une entrée")
    func equivalentAddressesShareOneRecord() throws {
        let store = InstanceReliabilityStore()
        store.recordSuccess(for: URL(string: "https://Searx.Example/")!, latency: .milliseconds(100), at: t0)

        let record = try #require(store.record(for: URL(string: "https://searx.example")!))
        #expect(record.successes == 1)

        let ordering = store.ordered(
            [URL(string: "https://searx.example")!, URL(string: "https://SEARX.example/")!],
            at: t0
        )
        #expect(ordering.active.count == 1)
    }

    @Test("Un verdict de sonde est enregistré comme un succès ou un échec")
    func recordsProbeResults() throws {
        let store = InstanceReliabilityStore()
        store.record(InstanceProbeResult(verdict: .healthy(resultCount: 4), latency: .milliseconds(250)), for: a, at: t0)
        store.record(InstanceProbeResult(verdict: .failed(.notJSON), latency: .milliseconds(90)), for: b, at: t0)

        #expect(store.record(for: a)?.successes == 1)
        let failed = try #require(store.record(for: b))
        #expect(failed.failures == 1)
        #expect(failed.lastFailureReason == .notJSON)
    }

    @Test("La mesure survit au redémarrage : un second store relit ce que le premier a écrit")
    func persistsAcrossStores() throws {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let first = InstanceReliabilityStore(userDefaults: defaults)
        first.recordSuccess(for: a, latency: .milliseconds(300), at: t0)
        first.recordFailure(for: b, reason: .accessDenied, at: t0)

        let second = InstanceReliabilityStore(userDefaults: defaults)
        #expect(second.record(for: a)?.successes == 1)
        let failed = try #require(second.record(for: b))
        #expect(failed.lastFailureReason == .accessDenied)
        #expect(failed.lastFailureAt == t0)
    }

    @Test("Un store en mémoire n'écrit rien dans les préférences")
    func inMemoryStoreDoesNotPersist() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        InstanceReliabilityStore().recordSuccess(for: a, latency: .milliseconds(10), at: t0)

        #expect(defaults.data(forKey: InstanceReliabilityStore.defaultsKey) == nil)
        #expect(InstanceReliabilityStore(userDefaults: defaults).record(for: a) == nil)
    }

    @Test("Des données illisibles sont ignorées : le store repart vide au lieu de planter")
    func corruptedDataStartsEmpty() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }
        defaults.set(Data("pas du JSON".utf8), forKey: InstanceReliabilityStore.defaultsKey)

        let store = InstanceReliabilityStore(userDefaults: defaults)

        #expect(store.record(for: a) == nil)
        store.recordSuccess(for: a, latency: .milliseconds(10), at: t0)
        #expect(InstanceReliabilityStore(userDefaults: defaults).record(for: a)?.successes == 1)
    }

    @Test("Au-delà du plafond, les entrées les plus anciennes sont oubliées")
    func prunesOldestRecords() {
        let store = InstanceReliabilityStore(maxRecords: 3)
        let urls = (0..<5).map { URL(string: "https://i\($0).example")! }
        for (index, url) in urls.enumerated() {
            store.recordSuccess(for: url, latency: .milliseconds(10), at: t0.addingTimeInterval(Double(index)))
        }

        #expect(store.record(for: urls[0]) == nil)
        #expect(store.record(for: urls[1]) == nil)
        #expect(store.record(for: urls[4]) != nil)
    }

    @Test("forget et resetAll effacent les fiches")
    func forgetAndReset() {
        let store = InstanceReliabilityStore()
        store.recordSuccess(for: a, latency: .milliseconds(10), at: t0)
        store.recordSuccess(for: b, latency: .milliseconds(10), at: t0)

        store.forget(a)
        #expect(store.record(for: a) == nil)
        #expect(store.record(for: b) != nil)

        store.resetAll()
        #expect(store.record(for: b) == nil)
    }
}
