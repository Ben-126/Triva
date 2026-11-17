//
//  InstanceAutoUpdateTests.swift
//  TrivaTests
//
//  Mission C3 (M13) : « Mettre à jour la liste automatiquement » coupe l'annuaire ET la re-sonde.
//

import Foundation
import Synchronization
import Testing
@testable import Triva

/// Faux rafraîchisseur : compte les appels. Classe + `Mutex` (voir `ScriptedInstanceClient`).
private nonisolated final class CountingRefresher: SearXNGDirectoryRefreshing, Sendable {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    func refreshIfNeeded(now: Date, force: Bool) async -> SearXNGDirectoryRefreshOutcome {
        count.withLock { $0 += 1 }
        return .updated(count: 0)
    }
}

@MainActor
@Suite("Mise à jour automatique des instances")
struct InstanceAutoUpdateTests {
    private let poor = URL(string: "https://mediocre.searx.example")!

    private func makeDefaults() throws -> UserDefaults {
        try #require(TestDefaults.suite(named: "test.instanceAutoUpdate.\(UUID().uuidString)"))
    }

    @Test("Activée par défaut, tant que rien n'a été réglé")
    func enabledByDefault() throws {
        let defaults = try makeDefaults()
        #expect(InstanceAutoUpdatePolicy.enabledByDefault)
        #expect(InstanceAutoUpdatePolicy.isEnabled(in: defaults))
    }

    @Test("Le réglage désactivé est relu, puis réactivé")
    func toggleRoundTrip() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: InstanceAutoUpdatePolicy.defaultsKey)
        #expect(!InstanceAutoUpdatePolicy.isEnabled(in: defaults))
        defaults.set(true, forKey: InstanceAutoUpdatePolicy.defaultsKey)
        #expect(InstanceAutoUpdatePolicy.isEnabled(in: defaults))
    }

    @Test("Désactivée : aucun passage, donc ni annuaire searx.space ni re-sonde")
    func disabledStopsRefreshAndProbe() async throws {
        let refresher = CountingRefresher()
        let prober = ScriptedProber(healthy: [poor])
        let reliability = InstanceReliabilityStore()
        let longAgo = Date().addingTimeInterval(-2 * 86_400)
        for _ in 0..<2 { reliability.recordFailure(for: poor, reason: .timeout, at: longAgo) }
        let enabled = Mutex(false)
        let maintenance = SearXNGMaintenance(
            refresher: refresher, prober: prober, isAutoUpdateEnabled: { enabled.withLock { $0 } }
        ) {
            FailoverManager(client: ScriptedInstanceClient(), instances: [poor], reliability: reliability)
        }

        #expect(maintenance.sceneDidBecomeActive() == nil)
        #expect(refresher.calls == 0)
        #expect(prober.probed.isEmpty)

        // Réactivée : le réglage est relu à chaque passage au premier plan, sans relancer l'app.
        enabled.withLock { $0 = true }
        let pass = try #require(maintenance.sceneDidBecomeActive())
        await pass.value
        #expect(refresher.calls == 1)
        #expect(prober.probed == [poor])
    }

    @Test("Activée par défaut : un passage a lieu sans rien régler")
    func defaultEnabledRuns() async throws {
        let refresher = CountingRefresher()
        let maintenance = SearXNGMaintenance(refresher: refresher, prober: ScriptedProber(healthy: [])) {
            FailoverManager(client: ScriptedInstanceClient(), instances: [])
        }
        // Le défaut lit `UserDefaults.standard` : une valeur désactivée laissée par un autre test
        // ou par la machine fausserait ce test ; on la neutralise le temps du test.
        let key = InstanceAutoUpdatePolicy.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } }

        let pass = try #require(maintenance.sceneDidBecomeActive())
        await pass.value
        #expect(refresher.calls == 1)
    }

    @Test("Le texte du réglage dit la vérité : annuaire, recherche « test », adresse IP")
    func footerMentionsWhatIsContacted() {
        #expect(InstanceAutoUpdateText.footer.contains("searx.space"))
        #expect(InstanceAutoUpdateText.footer.contains("test"))
        #expect(InstanceAutoUpdateText.footer.contains("adresse IP"))
    }
}
