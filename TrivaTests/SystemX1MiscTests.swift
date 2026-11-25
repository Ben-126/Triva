//
//  SystemX1MiscTests.swift
//  TrivaTests
//
//  Mission X1 : intents verrouillés, surveillance du temps d'arrière-plan, signal du partage, nettoyage du dossier de
//  travail de l'extension, texte + adresse partagés, nouvel essai de retrait Spotlight.
//

import AppIntents
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Triva

@Suite("X1 : intents et verrouillage")
struct SystemX1IntentPolicyTests {
    @Test("Chercher dans l'historique, ouvrir une conversation et changer le mode demandent un appareil déverrouillé")
    func historyIntentsRequireAuthentication() {
        #expect(SearchHistoryIntent.authenticationPolicy == .requiresAuthentication)
        #expect(OpenConversationIntent.authenticationPolicy == .requiresAuthentication)
        #expect(SetResponseModeIntent.authenticationPolicy == .requiresAuthentication)
    }

    @Test("Poser une question et ouvrir une nouvelle recherche restent permis écran verrouillé (décision réversible)")
    func askAndOpenStayAllowed() {
        #expect(AskTrivaIntent.authenticationPolicy == .alwaysAllowed)
        #expect(OpenComposerIntent.authenticationPolicy == .alwaysAllowed)
    }

    @Test("La description de « nouvelle recherche » ne promet plus une recherche vide")
    func openComposerDescription() {
        let text = String(localized: OpenComposerIntent.description.descriptionText)
        #expect(!text.contains("vide"))
    }

    @Test("Question coupée à 2 000 caractères : Siri le dit avant la réponse ; sinon la réponse seule")
    func spokenTruncationNotice() {
        let base = HeadlessAnswer(question: "q", text: "t", spoken: "Réponse.", sourceTitles: [], sourceLinks: [], conversationID: nil)
        #expect(AskTrivaIntent.spokenText(for: base) == "Réponse.")
        var cut = base
        cut.questionWasTruncated = true
        #expect(AskTrivaIntent.spokenText(for: cut) == "\(HeadlessAnswer.truncationNotice) Réponse.")
    }

    @MainActor
    @Test("Conversations demandées par identifiant : seules les connues, dans l'ordre demandé, sans charger l'historique entier")
    func entitiesByIdentifier() throws {
        let store = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
        let a = try store.createConversation(title: "A", now: Date(timeIntervalSince1970: 1_000))
        let b = try store.createConversation(title: "B", now: Date(timeIntervalSince1970: 2_000))
        let found = try ConversationQuery.entities(for: [b.id, UUID(), a.id], in: store)
        #expect(found.map(\.id) == [b.id, a.id])
        #expect(found.map(\.title) == ["B", "A"])
    }
}

@MainActor
@Suite("X1 : surveillance du temps d'arrière-plan")
struct SystemX1ExpiryMonitorTests {
    @MainActor
    private final class Remaining {
        var value: TimeInterval
        init(_ value: TimeInterval) { self.value = value }
    }

    @Test("La règle : prévenir à la marge ou en dessous, jamais au premier plan (temps énorme)")
    func rule() {
        #expect(BackgroundExpiryMonitor.shouldWarn(remaining: 5, margin: 6))
        #expect(BackgroundExpiryMonitor.shouldWarn(remaining: 6, margin: 6))
        #expect(!BackgroundExpiryMonitor.shouldWarn(remaining: 7, margin: 6))
        #expect(!BackgroundExpiryMonitor.shouldWarn(remaining: .greatestFiniteMagnitude, margin: 6))
    }

    @Test("Prévient UNE fois, quand il ne reste plus que la marge")
    func warnsOnce() async throws {
        let remaining = Remaining(30)
        var warnings = 0
        let monitor = BackgroundExpiryMonitor(remainingTime: { remaining.value }, margin: 6, pollInterval: .milliseconds(5)) { warnings += 1 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(warnings == 0)
        remaining.value = 4
        try await Task.sleep(for: .milliseconds(100))
        #expect(warnings == 1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(warnings == 1)
        monitor.cancel()
    }

    @Test("Annulée, elle ne prévient jamais")
    func cancelled() async throws {
        let remaining = Remaining(30)
        var warnings = 0
        let monitor = BackgroundExpiryMonitor(remainingTime: { remaining.value }, margin: 6, pollInterval: .milliseconds(5)) { warnings += 1 }
        monitor.cancel()
        remaining.value = 1
        try await Task.sleep(for: .milliseconds(80))
        #expect(warnings == 0)
    }
}

@Suite("X1 : signal du partage")
struct SystemX1ShareSignalTests {
    private final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test("Un signal posté arrive à l'observateur ; annulé, plus rien n'arrive")
    func roundTrip() async throws {
        let name = "com.benpodrojsky.Triva.tests.share-signal.\(UUID().uuidString)"
        let hits = Hits()
        let observation = try #require(ShareInboxSignal.observe(name: name) { hits.add() })
        ShareInboxSignal.post(name: name)
        for _ in 0..<100 where hits.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hits.value == 1)
        observation.cancel()
        ShareInboxSignal.post(name: name)
        try await Task.sleep(for: .milliseconds(100))
        #expect(hits.value == 1)
    }
}

@Suite("X1 : dossier de travail de l'extension de partage")
struct SystemX1StagingTests {
    @Test("Les dossiers anciens partent, les récents restent")
    func purgeStale() throws {
        let root = try TestFiles.makeFolder("x1staging"); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("vieux", isDirectory: true)
        let fresh = root.appendingPathComponent("recent", isDirectory: true)
        for folder in [old, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try TestFiles.write(SampleBytes.pdf(), named: "fichier", in: folder)
        }
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: fresh.path)
        ShareItemReader.purgeStaleStaging(in: root, olderThan: 300, now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("Racine absente : rien ne plante")
    func missingRoot() {
        ShareItemReader.purgeStaleStaging(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    }

    @MainActor
    @Test("Un texte ET une adresse partagés sans titre de page : le texte gagne sur l'adresse brute")
    func textBeatsBareAddress() async throws {
        let root = try TestFiles.makeFolder("x1reader"); defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.org/article"))
        let item = NSExtensionItem()
        item.attachments = [
            NSItemProvider(object: url as NSURL),
            NSItemProvider(object: "Un passage à retrouver" as NSString),
        ]
        let content = try await ShareItemReader.read([item], stagingDirectory: root.appendingPathComponent("staging"))
        #expect(content == .text("Un passage à retrouver"))
    }
}

@MainActor
@Suite("X1 : Spotlight, retrait refusé")
struct SystemX1SpotlightRetryTests {
    @Test("Si Spotlight refuse le retrait, l'indexeur réessaie seul et finit par vider l'index")
    func retriesPurge() async throws {
        let suite = "TrivaX1Spotlight-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        preferences.isSpotlightEnabled = true
        let client = FakeSpotlightClient()
        let entry = SpotlightEntry(id: UUID(), title: "Titre", updatedAt: Date(timeIntervalSince1970: 1_000))
        let indexer = SpotlightIndexer(
            client: client, preferences: preferences, defaults: defaults,
            delay: .zero, purgeRetryDelay: .milliseconds(60), loadEntries: { [entry] }
        )
        await indexer.syncNow()
        #expect(!indexer.indexedIDs.isEmpty)

        client.setFailsDeleteAll(true)
        preferences.isSpotlightEnabled = false
        await indexer.settingChanged()
        #expect(!indexer.indexedIDs.isEmpty, "le retrait a été refusé : les identifiants restent")

        client.setFailsDeleteAll(false)
        await indexer.settlePurgeRetries()
        #expect(indexer.indexedIDs.isEmpty)
        #expect(client.deleteAllCount == 1)
    }

    @Test("Réglage rallumé entre-temps : plus aucun nouvel essai de retrait")
    func retryStopsWhenReenabled() async throws {
        let suite = "TrivaX1Spotlight-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        preferences.isSpotlightEnabled = true
        let client = FakeSpotlightClient()
        let entry = SpotlightEntry(id: UUID(), title: "Titre", updatedAt: Date(timeIntervalSince1970: 1_000))
        let indexer = SpotlightIndexer(
            client: client, preferences: preferences, defaults: defaults,
            delay: .zero, purgeRetryDelay: .milliseconds(60), loadEntries: { [entry] }
        )
        await indexer.syncNow()
        client.setFailsDeleteAll(true)
        preferences.isSpotlightEnabled = false
        await indexer.settingChanged()
        client.setFailsDeleteAll(false)
        preferences.isSpotlightEnabled = true
        await indexer.settingChanged()
        await indexer.settlePurgeRetries()
        #expect(client.deleteAllCount == 0)
    }
}
