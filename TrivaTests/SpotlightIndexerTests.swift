//
//  SpotlightIndexerTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : l'index Spotlight suit l'historique (titres et dates), s'éteint avec le réglage et
//  se vide avec « Tout effacer ». Faux client, réglages jetables : jamais le vrai index.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Spotlight : indexeur")
struct SpotlightIndexerTests {
    @MainActor
    private struct Rig {
        let client = FakeSpotlightClient()
        let history = FakeSpotlightHistory()
        let defaults: UserDefaults
        let suiteName: String
        let indexer: SpotlightIndexer

        var preferences: SystemIntegrationPreferences { SystemIntegrationPreferences(defaults: defaults) }

        init(spotlightEnabled: Bool = true, delay: Duration = .zero) {
            suiteName = "TrivaSpotlightTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            SystemIntegrationPreferences(defaults: defaults).isSpotlightEnabled = spotlightEnabled
            let history = history
            indexer = SpotlightIndexer(
                client: client,
                preferences: SystemIntegrationPreferences(defaults: defaults),
                defaults: defaults,
                delay: delay,
                loadEntries: { try history.load() }
            )
        }

        func cleanup() { defaults.removePersistentDomain(forName: suiteName) }

        func entry(_ n: Int, title: String? = nil, at seconds: TimeInterval = 1_000) -> SpotlightEntry {
            SpotlightEntry(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                title: title ?? "Conversation \(n)",
                updatedAt: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Premier passage : toute la liste est indexée et les identifiants gardés dans les réglages de l'app")
    func firstSyncIndexesAll() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1), rig.entry(2)]

        await rig.indexer.syncNow()

        #expect(rig.client.allIndexed == rig.history.entries)
        #expect(rig.indexer.indexedIDs == Set(rig.history.entries.map(\.id)))
    }

    @Test("Les identifiants gardés sont de simples UUID : aucun titre n'est écrit dans les réglages")
    func storedIDsHoldNoTitles() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1, title: "Mon secret médical")]

        await rig.indexer.syncNow()

        let stored = rig.defaults.stringArray(forKey: SpotlightIndexer.indexedIDsKey) ?? []
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { UUID(uuidString: $0) != nil })
        let everything = rig.defaults.dictionaryRepresentation().description
        #expect(!everything.contains("secret"))
    }

    @Test("Rien n'a changé : aucun nouvel appel à l'index")
    func secondSyncIsQuiet() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()

        await rig.indexer.syncNow()

        #expect(rig.client.indexCallCount == 1)
        #expect(rig.client.deletedBatches.isEmpty)
    }

    @Test("Une nouvelle conversation est indexée seule ; un titre renommé est réindexé")
    func incrementalChanges() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()

        let added = rig.entry(2)
        rig.history.entries = [added, rig.entry(1)]
        await rig.indexer.syncNow()
        #expect(rig.client.indexedBatches.last == [added])

        let renamed = rig.entry(1, title: "Autre titre")
        rig.history.entries = [added, renamed]
        await rig.indexer.syncNow()
        #expect(rig.client.indexedBatches.last == [renamed])
    }

    @Test("Une conversation supprimée est retirée de l'index et des identifiants gardés")
    func deletionRemoves() async {
        let rig = Rig()
        defer { rig.cleanup() }
        let a = rig.entry(1)
        let b = rig.entry(2)
        rig.history.entries = [a, b]
        await rig.indexer.syncNow()

        rig.history.entries = [a]
        await rig.indexer.syncNow()

        #expect(rig.client.allDeleted == [b.id])
        #expect(rig.indexer.indexedIDs == [a.id])
    }

    @Test("Au plus 500 conversations sont envoyées")
    func sendsAtMostFiveHundred() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = (1...520).map { rig.entry($0) }

        await rig.indexer.syncNow()

        #expect(rig.client.allIndexed.count == 500)
        #expect(rig.indexer.indexedIDs.count == 500)
    }

    @Test("Réglage éteint : rien n'est indexé, même sur demande")
    func disabledIndexesNothing() async {
        let rig = Rig(spotlightEnabled: false)
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]

        rig.indexer.scheduleSync()
        await rig.indexer.syncNow()

        #expect(rig.client.indexCallCount == 0)
        #expect(rig.history.loadCount == 0)
    }

    @Test("Éteindre le réglage vide tout l'index et oublie les identifiants")
    func turningOffPurges() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1), rig.entry(2)]
        await rig.indexer.syncNow()

        rig.preferences.isSpotlightEnabled = false
        await rig.indexer.settingChanged()

        #expect(rig.client.deleteAllCount == 1)
        #expect(rig.indexer.indexedIDs.isEmpty)
    }

    @Test("Réglage éteint depuis le début et rien d'indexé : aucun appel inutile à l'index")
    func turnedOffWithNothingIndexedDoesNotCallIndex() async {
        let rig = Rig(spotlightEnabled: false)
        defer { rig.cleanup() }

        await rig.indexer.settingChanged()

        #expect(rig.client.deleteAllCount == 0)
    }

    @Test("Rallumer le réglage réindexe tout")
    func turningBackOnReindexes() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()
        rig.preferences.isSpotlightEnabled = false
        await rig.indexer.settingChanged()

        rig.preferences.isSpotlightEnabled = true
        await rig.indexer.settingChanged()
        await rig.indexer.syncNow()

        #expect(rig.client.indexCallCount == 2)
        #expect(rig.indexer.indexedIDs == [rig.entry(1).id])
    }

    @Test("Échec de l'index : pas d'oubli, la passe suivante recommence ; aucun plantage")
    func indexFailureRetries() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        rig.client.setFailsIndex(true)
        await rig.indexer.syncNow()
        #expect(rig.client.indexCallCount == 0)

        rig.client.setFailsIndex(false)
        await rig.indexer.syncNow()

        #expect(rig.client.allIndexed == [rig.entry(1)])
    }

    @Test("Historique illisible : rien n'est retiré par erreur, aucun plantage")
    func unreadableHistoryChangesNothing() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()

        rig.history.fails = true
        await rig.indexer.syncNow()

        #expect(rig.client.deletedBatches.isEmpty)
        #expect(rig.indexer.indexedIDs == [rig.entry(1).id])
    }

    @Test("« Tout effacer » : l'index est vidé, les identifiants oubliés, et le résultat est vrai")
    func eraseAllClears() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()

        let ok = await rig.indexer.eraseAll()

        #expect(ok)
        #expect(rig.client.deleteAllCount == 1)
        #expect(rig.indexer.indexedIDs.isEmpty)
    }

    @Test("« Tout effacer » vide l'index même quand le réglage est éteint")
    func eraseAllWorksWhenDisabled() async {
        let rig = Rig(spotlightEnabled: false)
        defer { rig.cleanup() }

        let ok = await rig.indexer.eraseAll()

        #expect(ok)
        #expect(rig.client.deleteAllCount == 1)
    }

    @Test("« Tout effacer » : si l'index ne se vide pas, le résultat est faux et les identifiants restent pour réessayer")
    func eraseAllFailureIsReported() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()
        rig.client.setFailsDeleteAll(true)

        let ok = await rig.indexer.eraseAll()

        #expect(ok == false)
        #expect(rig.indexer.indexedIDs == [rig.entry(1).id])
    }

    @Test("Après « Tout effacer », un historique encore plein (effacement raté) est réindexé à la passe suivante")
    func syncAfterEraseReindexes() async {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        await rig.indexer.syncNow()
        _ = await rig.indexer.eraseAll()

        await rig.indexer.syncNow()

        #expect(rig.client.indexCallCount == 2)
    }

    @Test("Plusieurs changements rapprochés : une seule passe, après l'attente")
    func changesAreDebounced() async throws {
        let rig = Rig(delay: .milliseconds(60))
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]

        rig.indexer.scheduleSync()
        rig.indexer.scheduleSync()
        rig.indexer.scheduleSync()
        #expect(rig.client.indexCallCount == 0)

        try await waitUntil { rig.client.indexCallCount >= 1 }
        try await Task.sleep(for: .milliseconds(150))

        #expect(rig.client.indexCallCount == 1)
        #expect(rig.history.loadCount == 1)
    }

    @Test("« Tout effacer » annule la passe en attente : rien n'est réindexé après coup")
    func eraseCancelsPendingSync() async throws {
        let rig = Rig(delay: .milliseconds(80))
        defer { rig.cleanup() }
        rig.history.entries = [rig.entry(1)]
        rig.indexer.scheduleSync()

        _ = await rig.indexer.eraseAll()
        try await Task.sleep(for: .milliseconds(200))

        #expect(rig.client.indexCallCount == 0)
    }
}
