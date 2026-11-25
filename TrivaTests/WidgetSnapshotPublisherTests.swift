//
//  WidgetSnapshotPublisherTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission C) : ce que l'app publie pour le widget. Règle de Ben (2026-11-24) : réglage « Dernière
//  question dans le widget » ÉTEINT (défaut) = AUCUNE question écrite dans l'App Group, et l'instantané existant
//  est effacé dès qu'on l'éteint. Tout se passe dans un dossier temporaire et une suite de réglages jetable.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Publication de l'instantané du widget")
struct WidgetSnapshotPublisherTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    private final class Harness {
        let root: URL
        let files: AppGroupFileStore
        let store: WidgetSnapshotStore
        let defaults: UserDefaults
        let suiteName: String
        var reloads = 0

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "TrivaPublisherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            files = AppGroupFileStore(directory: root)
            store = WidgetSnapshotStore(files: files)
            suiteName = "TrivaPublisherTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        var preferences: SystemIntegrationPreferences { SystemIntegrationPreferences(defaults: defaults) }

        func setShowsLastQuestion(_ value: Bool) { preferences.showsLastQuestionInWidget = value }

        func makePublisher(store override: WidgetSnapshotStore?? = nil) -> WidgetSnapshotPublisher {
            WidgetSnapshotPublisher(
                store: override ?? store,
                preferences: preferences,
                reload: { [unowned self] in reloads += 1 }
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func latest(title: String = "Recette de crêpes", at seconds: TimeInterval = 1_700_000_000)
        -> WidgetSnapshotPublisher.LatestConversation {
        .init(id: id, title: title, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Réglage éteint (défaut)

    @Test("Réglage éteint (défaut) : rien n'est écrit, aucune question n'atteint l'App Group, aucun rechargement")
    func offByDefaultWritesNothing() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let publisher = harness.makePublisher()

        let outcome = publisher.publish(latest: latest())

        #expect(outcome == .unchanged)
        #expect(harness.store.exists == false)
        #expect(harness.reloads == 0)
    }

    @Test("Éteindre le réglage efface l'instantané existant et recharge le widget, une seule fois")
    func turningOffRemovesSnapshot() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()
        #expect(publisher.publish(latest: latest()) == .written)
        #expect(harness.reloads == 1)

        harness.setShowsLastQuestion(false)
        let first = publisher.publish(latest: latest())
        let second = publisher.publish(latest: latest())

        #expect(first == .removed)
        #expect(second == .unchanged)
        #expect(harness.store.exists == false)
        #expect(harness.reloads == 2)
    }

    @Test("Éteint avec un fichier corrompu laissé là : il est supprimé aussi")
    func turningOffRemovesCorruptFile() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        try harness.files.write(Data("illisible".utf8), to: WidgetSnapshot.fileName)
        let publisher = harness.makePublisher()

        #expect(publisher.publish(latest: latest()) == .removed)
        #expect(harness.files.exists(WidgetSnapshot.fileName) == false)
    }

    // MARK: Réglage allumé

    @Test("Allumé, historique vide : instantané vide (« Aucune recherche pour l'instant »), widget rechargé")
    func onWithEmptyHistory() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()

        #expect(publisher.publish(latest: nil) == .written)

        #expect(harness.store.load() == .empty)
        #expect(harness.reloads == 1)
    }

    @Test("Allumé : la dernière conversation est écrite, titre nettoyé et coupé à 80")
    func onWritesLatestConversation() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()
        let longTitle = "  " + String(repeating: "x", count: 200) + "\n"

        #expect(publisher.publish(latest: latest(title: longTitle)) == .written)

        let stored = try #require(harness.store.load()?.conversation)
        #expect(stored.id == id)
        #expect(stored.title.count == WidgetSnapshot.maxTitleLength)
        #expect(stored.updatedAt == date)
    }

    @Test("Rechargement seulement si l'instantané a changé")
    func reloadsOnlyWhenChanged() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()

        #expect(publisher.publish(latest: latest()) == .written)
        #expect(publisher.publish(latest: latest()) == .unchanged)
        #expect(publisher.publish(latest: latest()) == .unchanged)
        #expect(harness.reloads == 1)

        #expect(publisher.publish(latest: latest(title: "Autre sujet")) == .written)
        #expect(harness.reloads == 2)
        #expect(publisher.publish(latest: latest(title: "Autre sujet")) == .unchanged)
        #expect(harness.reloads == 2)
    }

    @Test("Une date avec des fractions de seconde ne provoque pas de réécriture à chaque fois")
    func fractionalDateDoesNotRewrite() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()

        #expect(publisher.publish(latest: latest(at: 1_700_000_000.789)) == .written)
        #expect(publisher.publish(latest: latest(at: 1_700_000_000.789)) == .unchanged)
        #expect(harness.reloads == 1)
    }

    @Test("Un titre qui ne diffère que par des espaces autour ne provoque pas de réécriture")
    func whitespaceOnlyDifferenceDoesNotRewrite() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()

        #expect(publisher.publish(latest: latest(title: "Sujet")) == .written)
        #expect(publisher.publish(latest: latest(title: " Sujet\n")) == .unchanged)
    }

    @Test("Fichier corrompu laissé là, réglage allumé : il est réécrit proprement")
    func corruptFileIsRewritten() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        try harness.files.write(Data("illisible".utf8), to: WidgetSnapshot.fileName)
        let publisher = harness.makePublisher()

        #expect(publisher.publish(latest: latest()) == .written)
        #expect(harness.store.load()?.conversation?.title == "Recette de crêpes")
    }

    // MARK: Échecs

    @Test("App Group indisponible : résultat .unavailable, aucun rechargement, aucun plantage")
    func unavailableStore() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher(store: .some(nil))

        #expect(publisher.publish(latest: latest()) == .unavailable)
        #expect(publisher.erase() == .unavailable)
        #expect(harness.reloads == 0)
    }

    @Test("Écriture impossible : résultat .failed, widget NON rechargé")
    func writeFailure() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let blocker = harness.root.appending(path: "bloque")
        try Data("fichier".utf8).write(to: blocker)
        let broken = WidgetSnapshotStore(files: AppGroupFileStore(directory: blocker))
        let publisher = harness.makePublisher(store: .some(broken))

        let outcome = publisher.publish(latest: latest())

        guard case .failed = outcome else {
            Issue.record("attendu .failed, reçu \(outcome)")
            return
        }
        #expect(harness.reloads == 0)
    }

    // MARK: Tout effacer

    @Test("erase() supprime l'instantané et recharge ; une seconde fois ne fait rien")
    func eraseRemovesSnapshot() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.setShowsLastQuestion(true)
        let publisher = harness.makePublisher()
        _ = publisher.publish(latest: latest())
        #expect(harness.reloads == 1)

        #expect(publisher.erase() == .removed)
        #expect(publisher.erase() == .unchanged)
        #expect(harness.store.exists == false)
        #expect(harness.reloads == 2)
    }
}

@MainActor
@Suite("Intégrations système : branchement du widget sur l'historique")
struct SystemIntegrationsWidgetTests {
    @MainActor
    private struct Rig {
        let root: URL
        let store: WidgetSnapshotStore
        let history: ChatHistoryStore
        let defaults: UserDefaults
        let suiteName: String
        let integrations: SystemIntegrations
        let reloads: Counter

        final class Counter { var value = 0 }

        init(showsLastQuestion: Bool) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "TrivaIntegrationsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = WidgetSnapshotStore(files: AppGroupFileStore(directory: root))
            suiteName = "TrivaIntegrationsTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            let preferences = SystemIntegrationPreferences(defaults: defaults)
            preferences.showsLastQuestionInWidget = showsLastQuestion
            history = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
            let counter = Counter()
            reloads = counter
            // Tout est faux sauf ce que le test regarde : jamais le vrai App Group, le vrai index, les vraies activités.
            let localStore = store
            integrations = SystemIntegrations(
                makeWidgetPublisher: { WidgetSnapshotPublisher(store: localStore, preferences: preferences, reload: { counter.value += 1 }) },
                makeSharedInbox: { SharedInboxConsumer(inbox: nil) },
                spotlightClient: FakeSpotlightClient(),
                endLiveActivities: {},
                defaults: defaults
            )
            integrations.bind(chatHistory: history)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("start() publie l'état courant : la conversation la plus récemment modifiée")
    func startPublishesLatest() throws {
        let rig = try Rig(showsLastQuestion: true)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Ancienne", now: Date(timeIntervalSince1970: 1_000))
        let recent = try rig.history.createConversation(title: "Récente", now: Date(timeIntervalSince1970: 2_000))

        rig.integrations.start()

        let stored = try #require(rig.store.load()?.conversation)
        #expect(stored.id == recent.id)
        #expect(stored.title == "Récente")
    }

    @Test("historyDidChange() suit l'historique : une nouvelle conversation remplace la précédente")
    func historyChangeRepublishes() throws {
        let rig = try Rig(showsLastQuestion: true)
        defer { rig.cleanup() }
        rig.integrations.start()
        #expect(rig.store.load() == .empty)

        let created = try rig.history.createConversation(title: "Nouveau sujet", now: Date(timeIntervalSince1970: 5_000))
        rig.integrations.historyDidChange()

        #expect(rig.store.load()?.conversation?.id == created.id)
    }

    @Test("Réglage éteint : ni start() ni historyDidChange() n'écrivent quoi que ce soit")
    func offWritesNothing() throws {
        let rig = try Rig(showsLastQuestion: false)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Secret", now: Date(timeIntervalSince1970: 1_000))

        rig.integrations.start()
        rig.integrations.historyDidChange()

        #expect(rig.store.exists == false)
        #expect(rig.reloads.value == 0)
    }

    @Test("preferencesDidChange() : éteindre le réglage efface l'instantané")
    func preferencesChangeRemoves() throws {
        let rig = try Rig(showsLastQuestion: true)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Visible", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        #expect(rig.store.exists)

        SystemIntegrationPreferences(defaults: rig.defaults).showsLastQuestionInWidget = false
        rig.integrations.preferencesDidChange()

        #expect(rig.store.exists == false)
    }

    /// Attend (au plus 2 s) qu'une condition devienne vraie ; `Task.sleep`, jamais `Task.yield()` seul.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Éteindre le réglage SANS aucun appel explicite efface quand même l'instantané (réglage observé après start())")
    func turningOffIsObservedWithoutExplicitCall() async throws {
        let rig = try Rig(showsLastQuestion: true)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Visible", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        #expect(rig.store.exists)

        SystemIntegrationPreferences(defaults: rig.defaults).showsLastQuestionInWidget = false
        try await waitUntil { !rig.store.exists }

        #expect(rig.store.exists == false)
    }

    @Test("Allumer le réglage SANS appel explicite publie la dernière conversation")
    func turningOnIsObservedWithoutExplicitCall() async throws {
        let rig = try Rig(showsLastQuestion: false)
        defer { rig.cleanup() }
        let created = try rig.history.createConversation(title: "Récente", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        #expect(rig.store.exists == false)

        SystemIntegrationPreferences(defaults: rig.defaults).showsLastQuestionInWidget = true
        try await waitUntil { rig.store.exists }

        #expect(rig.store.load()?.conversation?.id == created.id)
    }

    @Test("Un autre réglage qui change ne republie rien et ne recharge pas le widget")
    func unrelatedSettingDoesNotRepublish() async throws {
        let rig = try Rig(showsLastQuestion: true)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "Visible", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        let reloadsAfterStart = rig.reloads.value

        SystemIntegrationPreferences(defaults: rig.defaults).isSpotlightEnabled = false
        rig.defaults.set("autre chose", forKey: "une.autre.cle")
        try await Task.sleep(for: .milliseconds(150))

        #expect(rig.reloads.value == reloadsAfterStart)
        #expect(rig.store.exists)
    }

    @Test("eraseAll() (Tout effacer) retire l'instantané")
    func eraseAllRemovesSnapshot() async throws {
        let rig = try Rig(showsLastQuestion: true)
        defer { rig.cleanup() }
        _ = try rig.history.createConversation(title: "À effacer", now: Date(timeIntervalSince1970: 1_000))
        rig.integrations.start()
        #expect(rig.store.exists)

        await rig.integrations.eraseAll()

        #expect(rig.store.exists == false)
    }

    @Test("Sans historique relié (tests, lancement précoce) : aucun plantage, rien d'écrit")
    func unboundDoesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "TrivaUnbound-\(UUID().uuidString)")
        let suite = "TrivaUnbound-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        preferences.showsLastQuestionInWidget = true
        let store = WidgetSnapshotStore(files: AppGroupFileStore(directory: root))
        let integrations = SystemIntegrations(
            makeWidgetPublisher: { WidgetSnapshotPublisher(store: store, preferences: preferences, reload: {}) },
            makeSharedInbox: { SharedInboxConsumer(inbox: nil) },
            spotlightClient: FakeSpotlightClient(),
            endLiveActivities: {},
            defaults: defaults
        )

        integrations.start()
        integrations.historyDidChange()

        #expect(store.exists == false)
    }
}
