//
//  SearXNGAppWiringTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 01/11/2026.
//

import Foundation
import Synchronization
import Testing
@testable import Triva

// Branchement de SearXNG fiabilisé (R3) dans l'app, mission RI1a : liste fusionnée (bundle,
// annuaire, personnalisations), mémoire de fiabilité partagée, entretien de fond. Aucun appel
// réseau : faux transport, fausse sonde, stores en mémoire, domaine `UserDefaults` jetable.

// MARK: - Outils

private enum WiringFixture {
    static let mine = URL(string: "https://searx.perso.example")!
    static let publicA = URL(string: "https://public-a.searx.example")!
    static let publicB = URL(string: "https://public-b.searx.example")!
    static let added = URL(string: "https://ajoutee.searx.example")!
    static let fromDirectory = URL(string: "https://annuaire.searx.example")!
    /// `publicA` écrite autrement (casse, barre finale) : la même instance.
    static let publicAOtherSpelling = URL(string: "https://PUBLIC-A.searx.example/")!

    /// Deux échecs il y a deux jours : mise de côté expirée, l'instance est « médiocre »,
    /// donc candidate à la re-sonde.
    static func makePoor(_ instance: URL, in store: InstanceReliabilityStore) {
        let longAgo = Date().addingTimeInterval(-2 * 86_400)
        for _ in 0..<2 { store.recordFailure(for: instance, reason: .timeout, at: longAgo) }
    }
}

/// Faux trousseau : aucune entrée/sortie, aucun accès au vrai Keychain.
private struct WiringTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

/// Stores jetables : domaine `UserDefaults` unique, base SwiftData en mémoire, faux trousseau,
/// liste du bundle explicite (jamais celle de `Bundle.main`, qui peut différer volontairement
/// d'une machine à l'autre), annuaire et fiabilité en mémoire.
@MainActor
private func makeWiringStores(
    bundled: [URL],
    overrides: SearXNGInstanceOverrides = .empty,
    directory: [URL] = [],
    reliability: InstanceReliabilityStore = InstanceReliabilityStore()
) throws -> TrivaSharedStores {
    let userDefaults = try #require(UserDefaults(suiteName: "test.searxngWiring.\(UUID().uuidString)"))
    overrides.save(to: userDefaults)
    let directoryStore = SearXNGDirectoryStore()
    if !directory.isEmpty {
        directoryStore.save(SearXNGDirectorySnapshot(instances: directory.map(\.absoluteString), updatedAt: Date()))
    }
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: bundled, userDefaults: userDefaults),
        keyStore: WiringTestKeyStore(),
        searchReliability: reliability,
        searchDirectory: directoryStore
    )
}

/// Faux rafraîchisseur : compte les appels et, fermé, retient le passage jusqu'à `open()`.
/// Classe + `Mutex` plutôt qu'`actor`, pour la même raison que `ScriptedInstanceClient`.
private final class GatedDirectoryRefresher: SearXNGDirectoryRefreshing, Sendable {
    private struct State {
        var calls = 0
        var isOpen: Bool
    }

    private let state: Mutex<State>

    init(isOpen: Bool) {
        state = Mutex(State(isOpen: isOpen))
    }

    var calls: Int { state.withLock { $0.calls } }

    func open() {
        state.withLock { $0.isOpen = true }
    }

    func refreshIfNeeded(now: Date, force: Bool) async -> SearXNGDirectoryRefreshOutcome {
        state.withLock { $0.calls += 1 }
        // `Task.sleep` et non `Task.yield()` : avec l'isolation main actor, `yield` ne garantit
        // pas que le test progresse (piège documenté du projet).
        while !state.withLock({ $0.isOpen }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return .skipped(until: now)
    }
}

/// Ce que voyait le rafraîchisseur au moment où l'entretien a construit son manager.
@MainActor
private final class ManagerBuildLog {
    var refreshCallsSeen: [Int] = []
}

@MainActor
private func waitForWiringCondition(_ condition: () -> Bool) async throws {
    var attempts = 0
    while !condition(), attempts < 2_000 {
        attempts += 1
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition(), "Condition jamais remplie en ~2 s")
}

/// Annuaire searx.space minimal : une instance qui passe tous les critères (forme de
/// `instances.json` relevée le 2026-10-28, voir `SearXNGDirectoryTests`). Sans horodatage :
/// la fraîcheur n'est alors pas jugée.
private func directoryJSON(listing instance: URL) throws -> Data {
    let entry: [String: Any] = [
        "network_type": "normal",
        "version": "2026.10.27+b5ed73fcb",
        "error": NSNull(),
        "analytics": false,
        "http": ["status_code": 200],
        "uptime": ["uptimeMonth": 99.5],
        "timing": ["search": ["success_percentage": 100.0, "error": NSNull(), "all": NSNull()]],
    ]
    return try JSONSerialization.data(withJSONObject: ["instances": [instance.absoluteString + "/": entry]])
}

// MARK: - Composition de la liste

@Suite("TrivaSharedStores.searXNGInstances — composition de la liste SearXNG")
struct SearXNGInstanceCompositionTests {
    private typealias F = WiringFixture

    @Test("Sans personnalisation ni annuaire : exactement la liste du bundle, dans son ordre")
    func bundleAlone() {
        let list = TrivaSharedStores.searXNGInstances(bundled: [F.mine, F.publicA], directory: [], overrides: .empty)
        #expect(list == [F.mine, F.publicA])
    }

    @Test("L'annuaire complète la liste APRÈS le bundle, sans doublon (même instance écrite autrement)")
    func directoryComesAfterTheBundle() {
        let list = TrivaSharedStores.searXNGInstances(
            bundled: [F.mine, F.publicA],
            directory: [F.publicAOtherSpelling, F.fromDirectory],
            overrides: .empty
        )
        #expect(list == [F.mine, F.publicA, F.fromDirectory])
    }

    @Test("Ajout en tête ; une instance masquée ne revient pas par l'annuaire")
    func customizationsApplyToTheDirectoryToo() {
        let overrides = SearXNGInstanceOverrides(
            addedInstances: [F.added.absoluteString],
            hiddenDefaultInstances: [F.publicB.absoluteString]
        )
        let list = TrivaSharedStores.searXNGInstances(
            bundled: [F.mine, F.publicA, F.publicB],
            directory: [F.publicB, F.fromDirectory],
            overrides: overrides
        )
        #expect(list == [F.added, F.mine, F.publicA, F.fromDirectory])
    }

    @Test("Toutes les instances par défaut masquées : l'annuaire n'en réintroduit aucune")
    func hidingEveryDefaultAlsoDropsTheDirectory() {
        let overrides = SearXNGInstanceOverrides(
            addedInstances: [F.added.absoluteString],
            hiddenDefaultInstances: [F.mine.absoluteString, F.publicA.absoluteString]
        )
        let list = TrivaSharedStores.searXNGInstances(
            bundled: [F.mine, F.publicA],
            directory: [F.fromDirectory],
            overrides: overrides
        )
        #expect(list == [F.added])
    }

    @Test("Liste du bundle illisible (vide) : l'annuaire sert quand même")
    func unreadableBundleStillUsesTheDirectory() {
        let list = TrivaSharedStores.searXNGInstances(bundled: [], directory: [F.fromDirectory], overrides: .empty)
        #expect(list == [F.fromDirectory])
    }
}

// MARK: - Session

@MainActor
@Suite("SearchSession — FailoverManager branché sur SearXNG fiabilisé")
struct SearchSessionSearXNGWiringTests {
    private typealias F = WiringFixture

    @Test("Le manager de la session : liste fusionnée et mémoire de fiabilité PARTAGÉE entre fenêtres")
    func sessionManagerUsesMergedListAndSharedReliability() async throws {
        let stores = try makeWiringStores(
            bundled: [F.mine, F.publicA, F.publicB],
            overrides: SearXNGInstanceOverrides(
                addedInstances: [F.added.absoluteString],
                hiddenDefaultInstances: [F.publicB.absoluteString]
            ),
            directory: [F.publicAOtherSpelling, F.fromDirectory, F.publicB]
        )
        let session = SearchSession(engine: .appleIntelligence, stores: stores)
        let otherWindow = SearchSession(engine: .appleIntelligence, stores: stores)

        let manager = session.resolveFailoverManager()

        #expect(await manager.instances == [F.added, F.mine, F.publicA, F.fromDirectory])
        #expect(await manager.instances == stores.searXNGInstances)
        #expect(await manager.reliability === stores.searchReliability)
        #expect(await otherWindow.resolveFailoverManager().reliability === stores.searchReliability)
    }

    @Test("Annuaire rafraîchi en cours de route : le manager suivant l'inclut, sans relancer l'app")
    func refreshedDirectoryRebuildsTheManager() async throws {
        let stores = try makeWiringStores(bundled: [F.mine])
        let session = SearchSession(engine: .appleIntelligence, stores: stores)
        let before = session.resolveFailoverManager()
        #expect(session.resolveFailoverManager() === before)

        stores.searchDirectory.save(SearXNGDirectorySnapshot(instances: [F.fromDirectory.absoluteString], updatedAt: Date()))

        let after = session.resolveFailoverManager()
        #expect(after !== before)
        #expect(await after.instances == [F.mine, F.fromDirectory])
        #expect(await after.reliability === stores.searchReliability)
        #expect(session.resolveFailoverManager() === after)
    }

    /// `live()` est le SEUL endroit où l'app choisit les stores persistés : tous les autres tests
    /// passent des stores en mémoire, donc retirer `.shared` de son appel les laisserait verts,
    /// alors que l'app repartirait d'une mémoire de fiabilité vide à chaque lancement.
    /// Sans effet de bord : l'app hôte des tests a déjà appelé `live()` à son lancement (mêmes
    /// lectures des réglages, du bundle et de la base), et rien n'est écrit ici.
    @Test("Stores réels : la session de l'app recherche avec la fiabilité et l'annuaire persistés `.shared`")
    func liveStoresUseTheSharedPersistentStores() async {
        let stores = TrivaSharedStores.live()

        #expect(stores.searchReliability === InstanceReliabilityStore.shared)
        #expect(stores.searchDirectory === SearXNGDirectoryStore.shared)
        let manager = SearchSession(engine: .appleIntelligence, stores: stores).resolveFailoverManager()
        #expect(await manager.reliability === InstanceReliabilityStore.shared)
    }
}

// MARK: - Entretien de fond

@MainActor
@Suite("SearXNGMaintenance — entretien de fond")
struct SearXNGMaintenanceTests {
    private typealias F = WiringFixture

    @Test("Un passage rafraîchit l'annuaire PUIS re-sonde, sur un manager construit après le rafraîchissement")
    func passRefreshesThenRetests() async throws {
        let refresher = GatedDirectoryRefresher(isOpen: true)
        let reliability = InstanceReliabilityStore()
        F.makePoor(F.publicA, in: reliability)
        let prober = ScriptedProber(healthy: [F.publicA])
        let log = ManagerBuildLog()
        let maintenance = SearXNGMaintenance(refresher: refresher, prober: prober) {
            log.refreshCallsSeen.append(refresher.calls)
            return FailoverManager(client: ScriptedInstanceClient(), instances: [F.publicA], reliability: reliability)
        }

        let pass = try #require(maintenance.sceneDidBecomeActive())
        await pass.value

        #expect(refresher.calls == 1)
        #expect(log.refreshCallsSeen == [1])
        #expect(prober.probed == [F.publicA])
        #expect(reliability.record(for: F.publicA)?.consecutiveFailures == 0)
        #expect(maintenance.inFlight == nil)
    }

    @Test("Une activation pendant un passage ne relance rien ; une fois le passage fini, si")
    func onePassAtATime() async throws {
        let refresher = GatedDirectoryRefresher(isOpen: false)
        let maintenance = SearXNGMaintenance(refresher: refresher, prober: ScriptedProber(healthy: [])) {
            FailoverManager(client: ScriptedInstanceClient(), instances: [])
        }

        let first = try #require(maintenance.sceneDidBecomeActive())
        #expect(maintenance.sceneDidBecomeActive() == nil)
        try await waitForWiringCondition { refresher.calls == 1 }
        #expect(maintenance.sceneDidBecomeActive() == nil)

        refresher.open()
        await first.value
        #expect(refresher.calls == 1)

        let second = try #require(maintenance.sceneDidBecomeActive())
        await second.value
        #expect(refresher.calls == 2)
    }

    /// La tâche ne démarre qu'après le retour de `sceneDidBecomeActive()` : si elle ne retenait
    /// pas l'entretien, un appel « lancé puis oublié » sur un entretien aussitôt relâché ne
    /// ferait rien du tout, sans la moindre erreur.
    @Test("Un passage lancé puis oublié va jusqu'au bout, même si l'entretien est aussitôt relâché")
    func passOutlivesItsOwner() async throws {
        let refresher = GatedDirectoryRefresher(isOpen: true)
        let pass = try #require(
            SearXNGMaintenance(refresher: refresher, prober: ScriptedProber(healthy: [])) {
                FailoverManager(client: ScriptedInstanceClient(), instances: [])
            }.sceneDidBecomeActive()
        )

        await pass.value

        #expect(refresher.calls == 1)
    }

    /// Le branchement réel (`TrivaSharedStores.makeSearXNGMaintenance`), réseau simulé :
    /// l'annuaire est écrit dans le store de l'app, la sonde de l'annuaire ne nourrit PAS la
    /// mémoire de fiabilité (sinon une instance publique passerait devant l'instance personnelle
    /// encore neutre), et la re-sonde voit la liste rafraîchie.
    @Test("Branchement réel : annuaire écrit dans les stores de l'app, fiabilité nourrie par la seule re-sonde")
    func liveWiringUsesTheAppStores() async throws {
        let reliability = InstanceReliabilityStore()
        F.makePoor(F.mine, in: reliability)
        let stores = try makeWiringStores(bundled: [F.mine], reliability: reliability)
        let body = try directoryJSON(listing: F.fromDirectory)
        let requester = BYOKTestRequester { _ in (body, 200) }
        let prober = ScriptedProber(healthy: [F.mine, F.fromDirectory])

        let maintenance = stores.makeSearXNGMaintenance(requester: requester, prober: prober)
        let pass = try #require(maintenance.sceneDidBecomeActive())
        await pass.value

        #expect(maintenance.inFlight == nil)
        #expect(requester.requests.compactMap(\.url) == [SearXNGDirectoryRefresher.directoryURL])
        #expect(stores.searchDirectory.refreshedInstances == [F.fromDirectory])
        #expect(stores.searXNGInstances == [F.mine, F.fromDirectory])
        // Sondée par le rafraîchisseur, mais aucune fiche : elle reste neutre, derrière le bundle.
        #expect(reliability.record(for: F.fromDirectory) == nil)
        // Re-sondée par l'entretien (médiocre, délai expiré) : la réponse est enregistrée.
        #expect(reliability.record(for: F.mine)?.consecutiveFailures == 0)
        #expect(prober.probed.sorted { $0.absoluteString < $1.absoluteString } == [F.fromDirectory, F.mine])
    }
}
