//
//  SystemX1IntegrationsTests.swift
//  TrivaTests
//
//  Mission X1 : widget retiré sans lire l'historique, activité en direct terminée quand on l'éteint ou quand sa
//  conversation disparaît, « Tout effacer » honnête pour la boîte de partage. Faux client, dossiers temporaires,
//  réglages jetables : jamais le vrai App Group ni les vraies activités.
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class X1Counter {
    var value = 0
    var existsProbe: (@MainActor (UUID) -> Bool)?
}

@MainActor
private struct IntegrationsRig {
    let root: URL
    let inboxDirectory: URL
    let widgetStore: WidgetSnapshotStore
    let history: ChatHistoryStore
    let defaults: UserDefaults
    let suiteName: String
    let ends = X1Counter()
    let orphans = X1Counter()
    let integrations: SystemIntegrations

    var preferences: SystemIntegrationPreferences { SystemIntegrationPreferences(defaults: defaults) }

    init(showsLastQuestion: Bool = false, bindHistory: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TrivaX1Integrations-\(UUID().uuidString)", directoryHint: .isDirectory)
        let widgetDirectory = root.appending(path: "widget", directoryHint: .isDirectory)
        inboxDirectory = root.appending(path: "inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        let store = WidgetSnapshotStore(files: AppGroupFileStore(directory: widgetDirectory))
        widgetStore = store
        try store.save(WidgetSnapshot(conversationID: UUID(), title: "Question privée", updatedAt: Date(timeIntervalSince1970: 5)))
        suiteName = "TrivaX1Integrations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        self.defaults = defaults
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        preferences.showsLastQuestionInWidget = showsLastQuestion
        preferences.isSpotlightEnabled = false
        history = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))

        let ends = ends
        let orphans = orphans
        let inbox = SharedInbox(directory: inboxDirectory)
        let center = SystemRouteCenter(windowLauncher: nil)
        integrations = SystemIntegrations(
            makeWidgetPublisher: { WidgetSnapshotPublisher(store: store, preferences: preferences, reload: {}) },
            makeSharedInbox: { SharedInboxConsumer(inbox: inbox, center: center) },
            spotlightClient: FakeSpotlightClient(),
            spotlightDelay: .zero,
            endLiveActivities: { ends.value += 1 },
            endOrphanedLiveActivities: { exists in
                orphans.value += 1
                orphans.existsProbe = exists
            },
            routes: center,
            defaults: defaults,
            isMac: false
        )
        if bindHistory { integrations.bind(chatHistory: history) }
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inboxDirectory.path)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<150 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite("X1 : intégrations système")
struct SystemX1IntegrationsTests {
    @Test("Widget éteint : l'instantané est retiré même quand l'historique n'est pas lisible ou pas relié")
    func widgetOffRemovesWithoutHistory() throws {
        let rig = try IntegrationsRig(showsLastQuestion: false, bindHistory: false)
        defer { rig.cleanup() }
        #expect(rig.widgetStore.exists)
        rig.integrations.historyDidChange()
        #expect(!rig.widgetStore.exists)
    }

    @Test("Widget allumé mais historique non relié : l'instantané est laissé en l'état (jamais un historique « vide » inventé)")
    func widgetOnWithoutHistoryKeepsSnapshot() throws {
        let rig = try IntegrationsRig(showsLastQuestion: true, bindHistory: false)
        defer { rig.cleanup() }
        rig.integrations.historyDidChange()
        #expect(rig.widgetStore.exists)
    }

    @Test("Éteindre « Activité en direct » (bascule explicite) termine les activités")
    func liveActivityOffExplicit() async throws {
        let rig = try IntegrationsRig()
        defer { rig.cleanup() }
        rig.preferences.isLiveActivityEnabled = false
        rig.integrations.preferencesDidChange()
        try await waitUntil { rig.ends.value >= 1 }
        #expect(rig.ends.value == 1)
    }

    @Test("Éteindre « Activité en direct » (écoute des réglages, depuis n'importe quel écran) termine les activités")
    func liveActivityOffObserved() async throws {
        let rig = try IntegrationsRig()
        defer { rig.cleanup() }
        rig.integrations.start()
        try await waitUntil { rig.ends.value >= 1 }   // la fermeture des activités orphelines du lancement
        let baseline = rig.ends.value
        rig.preferences.isLiveActivityEnabled = false
        try await waitUntil { rig.ends.value > baseline }
        #expect(rig.ends.value == baseline + 1)
        // Rallumer ne termine rien.
        rig.preferences.isLiveActivityEnabled = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.ends.value == baseline + 1)
    }

    @Test("Changement d'historique : les activités dont la conversation a disparu sont examinées avec le vrai historique")
    func historyChangeReapsOrphans() async throws {
        let rig = try IntegrationsRig()
        defer { rig.cleanup() }
        let known = try rig.history.createConversation(title: "Existe", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.historyDidChange()
        try await waitUntil { rig.orphans.existsProbe != nil }
        let exists = try #require(rig.orphans.existsProbe)
        #expect(exists(known.id))
        #expect(!exists(UUID()))
    }

    @Test("« Tout effacer » dit faux quand la boîte de partage garde un fichier")
    func eraseAllReportsInboxFailure() async throws {
        let rig = try IntegrationsRig()
        defer { rig.cleanup() }
        try Data("x".utf8).write(to: rig.inboxDirectory.appending(path: "reste.payload"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.inboxDirectory.path)
        let complete = await rig.integrations.eraseAll()
        #expect(!complete)
        #expect(rig.ends.value == 1, "les autres intégrations sont quand même vidées")
    }
}

// MARK: - Contrôleur d'activité : conversation disparue

@MainActor
private final class ReapClient: LiveActivityClient {
    var areActivitiesEnabled = true
    var open: [OpenLiveActivity] = []
    private(set) var dismissed: [String] = []

    func start(attributes: SearchActivityAttributes, state: SearchActivityState, staleDate: Date) throws -> String { "live-1" }
    func update(id: String, state: SearchActivityState, staleDate: Date) async {}
    func end(id: String, state: SearchActivityState, policy: LiveActivityEndPolicy) async {}
    func endAll() async {}
    func openActivities() -> [OpenLiveActivity] { open }
    func dismiss(id: String) async { dismissed.append(id) }
}

@MainActor
private final class ReapKeeper: BackgroundRunKeeping {
    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> BackgroundRunToken? { nil }
    func end(_ token: BackgroundRunToken) {}
}

@MainActor
@Suite("X1 : activité en direct d'une conversation supprimée")
struct SystemX1ReapActivityTests {
    private func makeController(_ client: ReapClient) -> SearchLiveActivityController {
        let suite = "TrivaX1Reap-\(UUID().uuidString)"
        return SearchLiveActivityController(
            client: client,
            keeper: ReapKeeper(),
            preferences: SystemIntegrationPreferences(defaults: UserDefaults(suiteName: suite)!),
            isAppActive: { true }
        )
    }

    @Test("Seules les activités terminées dont la conversation n'existe plus sont retirées")
    func onlyMissingConversationsAreDismissed() async {
        let client = ReapClient()
        let kept = UUID(), gone = UUID()
        client.open = [
            OpenLiveActivity(id: "a", conversationID: kept),
            OpenLiveActivity(id: "b", conversationID: gone),
            OpenLiveActivity(id: "c", conversationID: nil),
        ]
        let controller = makeController(client)
        await controller.endActivities(whereConversationIsMissing: { $0 == kept })
        #expect(client.dismissed == ["b"])
    }

    @Test("Un échange EN COURS n'est jamais retiré (sa conversation peut ne pas être encore enregistrée)")
    func inFlightIsNeverDismissed() async {
        let client = ReapClient()
        let controller = makeController(client)
        let conversation = UUID()
        controller.searchProgress(.started(question: "Q ?", conversationID: conversation), answerID: UUID())
        await controller.settle()
        client.open = [OpenLiveActivity(id: "live-1", conversationID: conversation)]
        await controller.endActivities(whereConversationIsMissing: { _ in false })
        #expect(client.dismissed.isEmpty)
    }
}
