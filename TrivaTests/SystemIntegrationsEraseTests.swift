//
//  SystemIntegrationsEraseTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : « Tout effacer » vide l'instantané du widget, la boîte de partage (fichiers compris),
//  l'index Spotlight et les activités en direct ; Spotlight suit l'historique et son réglage ; sur Mac, le conteneur
//  de l'App Group n'est pas touché tant que le widget n'a jamais été allumé.
//  Tout est faux ou temporaire : jamais le vrai App Group, le vrai index ni les vraies activités.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Intégrations système : effacement, Spotlight et Mac")
struct SystemIntegrationsEraseTests {
    @MainActor
    private final class Counter { var value = 0 }

    @MainActor
    private struct Rig {
        let root: URL
        let inboxDirectory: URL
        let widgetStore: WidgetSnapshotStore
        let history: ChatHistoryStore
        let defaults: UserDefaults
        let suiteName: String
        let client = FakeSpotlightClient()
        let widgetFactoryCalls = Counter()
        let inboxFactoryCalls = Counter()
        let activityEnds = Counter()
        let integrations: SystemIntegrations

        var preferences: SystemIntegrationPreferences { SystemIntegrationPreferences(defaults: defaults) }
        var inboxExists: Bool { FileManager.default.fileExists(atPath: inboxDirectory.path) }

        /// - Parameter plantedSnapshot: un instantané déjà présent sur le disque (ce que ferait un lancement précédent).
        init(isMac: Bool, showsLastQuestion: Bool = false, spotlight: Bool = true, plantedSnapshot: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "TrivaEraseTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let widgetDirectory = root.appending(path: "widget", directoryHint: .isDirectory)
            inboxDirectory = root.appending(path: "inbox", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: inboxDirectory.appending(path: "entree.json"))
            let store = WidgetSnapshotStore(files: AppGroupFileStore(directory: widgetDirectory))
            widgetStore = store
            if plantedSnapshot {
                try store.save(WidgetSnapshot(conversationID: UUID(), title: "Question privée", updatedAt: Date(timeIntervalSince1970: 5)))
            }
            let name = "TrivaEraseTests-\(UUID().uuidString)"
            suiteName = name
            let defaults = UserDefaults(suiteName: name)!
            self.defaults = defaults
            let preferences = SystemIntegrationPreferences(defaults: defaults)
            preferences.showsLastQuestionInWidget = showsLastQuestion
            preferences.isSpotlightEnabled = spotlight
            history = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))

            let widgetCalls = widgetFactoryCalls
            let inboxCalls = inboxFactoryCalls
            let ends = activityEnds
            let inbox = SharedInbox(directory: inboxDirectory)
            integrations = SystemIntegrations(
                makeWidgetPublisher: {
                    widgetCalls.value += 1
                    return WidgetSnapshotPublisher(store: store, preferences: preferences, reload: {})
                },
                makeSharedInbox: {
                    inboxCalls.value += 1
                    return SharedInboxConsumer(inbox: inbox)
                },
                spotlightClient: client,
                spotlightDelay: .zero,
                endLiveActivities: { ends.value += 1 },
                defaults: defaults,
                isMac: isMac
            )
            integrations.bind(chatHistory: history)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Tout effacer

    @Test("iPhone et iPad : « Tout effacer » vide l'instantané, la boîte de partage, l'index et les activités")
    func eraseAllEmptiesEverything() async throws {
        let rig = try Rig(isMac: false)
        defer { rig.cleanup() }

        let complete = await rig.integrations.eraseAll()

        #expect(complete)
        #expect(rig.widgetStore.exists == false)
        #expect(rig.inboxExists == false)
        #expect(rig.client.deleteAllCount == 1)
        #expect(rig.activityEnds.value == 1)
    }

    @Test("« Tout effacer » vide tout même quand l'index Spotlight refuse, et le dit")
    func eraseAllReportsSpotlightFailure() async throws {
        let rig = try Rig(isMac: false)
        defer { rig.cleanup() }
        rig.client.setFailsDeleteAll(true)

        let complete = await rig.integrations.eraseAll()

        #expect(complete == false)
        #expect(rig.widgetStore.exists == false)
        #expect(rig.inboxExists == false)
        #expect(rig.activityEnds.value == 1)
    }

    @Test("« Tout effacer » vide l'instantané et l'index même quand les réglages sont éteints")
    func eraseAllIgnoresSettings() async throws {
        let rig = try Rig(isMac: false, showsLastQuestion: false, spotlight: false)
        defer { rig.cleanup() }

        _ = await rig.integrations.eraseAll()

        #expect(rig.widgetStore.exists == false)
        #expect(rig.client.deleteAllCount == 1)
    }

    // MARK: Mac : l'App Group n'est pas touché au lancement

    @Test("Mac, widget jamais allumé : le lancement ne crée ni ne touche rien dans l'App Group")
    func macLaunchLeavesAppGroupAlone() async throws {
        let rig = try Rig(isMac: true)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Une question", now: Date(timeIntervalSince1970: 1_000))

        rig.integrations.start()
        rig.integrations.historyDidChange()
        rig.integrations.sceneDidBecomeActive()

        #expect(rig.widgetFactoryCalls.value == 0)
        #expect(rig.inboxFactoryCalls.value == 0)
        #expect(rig.widgetStore.exists, "le fichier planté n'a pas été touché")
        #expect(rig.inboxExists)
    }

    @Test("Mac, widget jamais allumé : « Tout effacer » ne touche pas l'App Group, mais vide l'index et les activités")
    func macEraseAllSkipsAppGroup() async throws {
        let rig = try Rig(isMac: true)
        defer { rig.cleanup() }

        let complete = await rig.integrations.eraseAll()

        #expect(complete)
        #expect(rig.widgetFactoryCalls.value == 0)
        #expect(rig.inboxFactoryCalls.value == 0)
        #expect(rig.widgetStore.exists)
        #expect(rig.client.deleteAllCount == 1)
        #expect(rig.activityEnds.value == 1)
    }

    @Test("Mac, widget allumé : l'instantané est publié ; « Tout effacer » le retire, mais jamais la boîte de partage (iPhone et iPad seulement)")
    func macAfterEnablingWidget() async throws {
        let rig = try Rig(isMac: true, showsLastQuestion: true, plantedSnapshot: false)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Visible", now: Date(timeIntervalSince1970: 1_000))

        rig.integrations.start()
        #expect(rig.widgetStore.exists)

        _ = await rig.integrations.eraseAll()
        #expect(rig.widgetStore.exists == false)
        #expect(rig.inboxFactoryCalls.value == 0)
        #expect(rig.inboxExists)
    }

    @Test("Mac : allumer le réglage après le lancement publie, éteindre ensuite retire encore l'instantané")
    func macEnableThenDisable() async throws {
        let rig = try Rig(isMac: true, plantedSnapshot: false)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Récente", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        #expect(rig.widgetFactoryCalls.value == 0)

        rig.preferences.showsLastQuestionInWidget = true
        try await waitUntil { rig.widgetStore.exists }
        #expect(rig.widgetStore.exists)

        rig.preferences.showsLastQuestionInWidget = false
        try await waitUntil { !rig.widgetStore.exists }
        #expect(rig.widgetStore.exists == false)
    }

    // MARK: Spotlight

    @Test("L'historique est indexé au lancement : titre et date seulement, les plus récentes d'abord")
    func startIndexesHistory() async throws {
        let rig = try Rig(isMac: false)
        defer { rig.cleanup() }
        let older = try rig.history.createConversation(title: "Ancienne", now: Date(timeIntervalSince1970: 1_000))
        let newer = try rig.history.createConversation(title: "Récente", now: Date(timeIntervalSince1970: 2_000))

        rig.integrations.start()
        try await waitUntil { rig.client.indexCallCount >= 1 }

        let indexed = rig.client.allIndexed
        #expect(indexed.map(\.id) == [newer.id, older.id])
        #expect(indexed.map(\.title) == ["Récente", "Ancienne"])
    }

    @Test("Un changement d'historique est suivi, une conversation supprimée est retirée de l'index")
    func historyChangesAreFollowed() async throws {
        let rig = try Rig(isMac: false)
        defer { rig.cleanup() }
        let first = try rig.history.createConversation(title: "Première", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        try await waitUntil { rig.client.indexCallCount >= 1 }

        let second = try rig.history.createConversation(title: "Seconde", now: Date(timeIntervalSince1970: 2_000))
        rig.integrations.historyDidChange()
        try await waitUntil { rig.client.indexCallCount >= 2 }
        #expect(rig.client.indexedBatches.last?.map(\.id) == [second.id])

        let firstID = first.id
        try rig.history.delete(first)
        rig.integrations.historyDidChange()
        try await waitUntil { !rig.client.allDeleted.isEmpty }
        #expect(rig.client.allDeleted == [firstID])
    }

    @Test("Éteindre Spotlight (sans appel explicite) vide l'index ; le rallumer réindexe")
    func spotlightSettingIsObserved() async throws {
        let rig = try Rig(isMac: false)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Une", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        try await waitUntil { rig.client.indexCallCount >= 1 }

        rig.preferences.isSpotlightEnabled = false
        try await waitUntil { rig.client.deleteAllCount >= 1 }
        #expect(rig.client.deleteAllCount == 1)

        rig.preferences.isSpotlightEnabled = true
        try await waitUntil { rig.client.indexCallCount >= 2 }
        #expect(rig.client.indexCallCount == 2)
    }

    @Test("Réglage Spotlight éteint : le lancement et l'historique n'indexent rien")
    func spotlightOffIndexesNothing() async throws {
        let rig = try Rig(isMac: false, spotlight: false)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Une", now: Date(timeIntervalSince1970: 1_000))

        rig.integrations.start()
        rig.integrations.historyDidChange()
        try await Task.sleep(for: .milliseconds(150))

        #expect(rig.client.indexCallCount == 0)
    }

    @Test("Historique pas encore relié : rien n'est retiré de l'index par erreur")
    func unboundHistoryRemovesNothing() async throws {
        let rig = try Rig(isMac: false)
        defer { rig.cleanup() }
        let unbound = SystemIntegrations(
            makeWidgetPublisher: { WidgetSnapshotPublisher(store: rig.widgetStore, preferences: rig.preferences, reload: {}) },
            makeSharedInbox: { SharedInboxConsumer(inbox: nil) },
            spotlightClient: rig.client,
            spotlightDelay: .zero,
            endLiveActivities: {},
            defaults: rig.defaults,
            isMac: false
        )

        unbound.start()
        unbound.historyDidChange()
        try await Task.sleep(for: .milliseconds(150))

        #expect(rig.client.deletedBatches.isEmpty)
        #expect(rig.client.deleteAllCount == 0)
        #expect(rig.client.indexCallCount == 0)
    }
}
