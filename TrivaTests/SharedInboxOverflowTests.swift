//
//  SharedInboxOverflowTests.swift
//  TrivaTests
//
//  F3 (26/11) : la boîte garde 10 partages au plus ; au-delà, les plus anciens sont retirés ET Triva le dit à la reprise
//  (« 2 partages plus anciens n'ont pas pu être gardés. »). L'extension, qui écrit, laisse un petit marqueur par partage
//  retiré dans l'App Group ; l'app les compte une fois, puis les efface. Tout est dans des dossiers temporaires.
//

import Foundation
import Testing
@testable import Triva

private struct OverflowRig {
    let root: URL
    let inboxDirectory: URL
    let depositRoot: URL
    let clock = TestClock()

    var inbox: SharedInbox {
        let clock = clock
        return SharedInbox(directory: inboxDirectory, now: { clock.date })
    }

    init() throws {
        root = try TestFiles.makeFolder("overflow")
        inboxDirectory = root.appendingPathComponent("share-inbox", isDirectory: true)
        depositRoot = root.appendingPathComponent("vault", isDirectory: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// `count` partages de texte, un par seconde (le plus ancien d'abord).
    func addTexts(_ count: Int) throws {
        for index in 1...count {
            try inbox.add(text: "texte \(index)", fileAt: nil, displayName: nil)
            clock.advance(1)
        }
    }

    func markerNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory.path)) ?? []).filter { $0.hasSuffix(".dropped") }
    }

    @MainActor
    func makeConsumer() -> (SharedInboxConsumer, SystemRouteCenter) {
        let center = SystemRouteCenter(windowLauncher: nil, depositRoot: depositRoot)
        return (SharedInboxConsumer(inbox: inbox, center: center, depositRoot: depositRoot), center)
    }
}

@Suite("Partage : débordement de la boîte (F3), côté boîte")
struct SharedInboxOverflowInboxTests {
    @Test("12 partages : les 10 plus récents restent, les 2 retirés sont comptés UNE fois")
    func droppedSharesAreCountedOnce() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(12)
        #expect(rig.inbox.validEntries().count == 10)
        #expect(rig.inbox.takeDroppedCount() == 2)
        #expect(rig.inbox.takeDroppedCount() == 0, "déjà annoncés : plus rien à dire")
        #expect(rig.markerNames().isEmpty)
    }

    @Test("Pile 10 partages : rien n'est retiré, rien à annoncer")
    func exactlyTenDropsNothing() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(10)
        #expect(rig.inbox.validEntries().count == 10)
        #expect(rig.inbox.takeDroppedCount() == 0)
    }

    @Test("Le marqueur survit au ménage des orphelins (plus de 10 minutes) et se compte encore")
    func markersSurviveTheOrphanSweep() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(11)
        rig.clock.advance(SharedInbox.orphanGrace + 60)
        _ = rig.inbox.validEntries()
        #expect(rig.markerNames().count == 1)
        #expect(rig.inbox.takeDroppedCount() == 1)
    }

    @Test("Un marqueur de plus de 24 h n'est pas annoncé (l'entrée aurait expiré de toute façon) et est effacé")
    func staleMarkersAreDiscarded() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(11)
        rig.clock.advance(SharedInbox.maxAge + 60)
        #expect(rig.inbox.takeDroppedCount() == 0)
        #expect(rig.markerNames().isEmpty)
    }

    @Test("Entrées expirées ou abîmées : retirées sans être annoncées comme « plus anciens partages »")
    func expiredOrBrokenEntriesAreNotCounted() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        let old = try rig.inbox.add(text: "ancien", fileAt: nil, displayName: nil)
        let broken = try rig.inbox.add(text: "abîmé", fileAt: nil, displayName: nil)
        try Data("pas du json".utf8).write(to: rig.inboxDirectory.appendingPathComponent("\(broken.id.uuidString).json"))
        rig.clock.advance(SharedInbox.maxAge + 60)
        #expect(rig.inbox.validEntries().isEmpty)
        #expect(rig.inbox.takeDroppedCount() == 0)
        #expect(old.id != broken.id)
    }

    @Test("« Tout effacer » vide aussi les marqueurs")
    func eraseAllClearsMarkers() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(12)
        #expect(rig.inbox.removeAll())
        #expect(rig.inbox.takeDroppedCount() == 0)
    }

    @Test("Le marqueur ne porte ni texte ni nom de fichier")
    func markersCarryNoContent() throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(11)
        let name = try #require(rig.markerNames().first)
        let data = try Data(contentsOf: rig.inboxDirectory.appendingPathComponent(name))
        #expect(data.isEmpty)
    }
}

@MainActor
@Suite("Partage : débordement de la boîte (F3), côté reprise et fenêtre")
struct SharedInboxOverflowConsumerTests {
    @Test("12 partages : 10 repris, et l'information « 2 plus anciens » arrive en dernier, une seule fois")
    func consumerAnnouncesDroppedShares() async throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(12)
        let (consumer, center) = rig.makeConsumer()
        await consumer.takeOver()
        let routes = center.drain()
        #expect(routes.count == 11)
        #expect(routes.last == .notice(.sharesDropped(2)))
        #expect(routes.first == .draft("texte 3"), "les deux plus anciens n'ont pas été gardés")
        await consumer.takeOver()
        #expect(center.drain().isEmpty, "annoncé une seule fois")
    }

    @Test("Aucun partage valide mais des marqueurs : l'information est quand même donnée")
    func noticeWithoutAnyHandoff() async throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        try rig.addTexts(11)
        for entry in rig.inbox.validEntries() { rig.inbox.remove(entry) }
        let (consumer, center) = rig.makeConsumer()
        await consumer.takeOver()
        #expect(center.drain() == [.notice(.sharesDropped(1))])
    }

    @Test("Dix partages avec fichier et texte, un texte coupé et un retrait : 22 routes, aucune évincée de la file")
    func tenSharesStillFitTheQueue() async throws {
        let rig = try OverflowRig(); defer { rig.cleanUp() }
        for index in 1...11 {
            let source = try TestFiles.write(SampleBytes.pdf(padding: 200), named: "src-\(index).pdf", in: rig.root)
            let text = index == 5 ? String(repeating: "x", count: 2_600) : "texte \(index)"
            try rig.inbox.add(text: text, fileAt: source, displayName: "f\(index).pdf")
            rig.clock.advance(1)
        }
        let (consumer, center) = rig.makeConsumer()
        await consumer.takeOver()
        let routes = center.drain()
        let attachments = routes.filter { if case .attachment = $0 { true } else { false } }
        #expect(attachments.count == 10)
        #expect(routes.suffix(2) == [.notice(.truncatedText), .notice(.sharesDropped(1))])
        #expect(routes.count == 10 + 10 + 2)
        #expect(SystemRouteCenter.maxPending >= routes.count + 8, "de la marge pour d'autres routes en attente")
    }

    @Test("Textes de l'information : pluriel et singulier, sans nom ni contenu")
    func noticeMessages() {
        #expect(SystemNoticeMessages.sharesDropped(count: 2) == "2 partages plus anciens n'ont pas pu être gardés.")
        #expect(SystemNoticeMessages.sharesDropped(count: 1) == "1 partage plus ancien n'a pas pu être gardé.")
        #expect(SystemNoticeMessages.sharesDropped(count: 14) == "14 partages plus anciens n'ont pas pu être gardés.")
    }

    @Test("La fenêtre affiche l'information sous les capsules, sans rien joindre ni envoyer")
    func windowShowsTheNotice() throws {
        let userDefaults = try #require(TestDefaults.suite(named: "test.overflow.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
            keyStore: OverflowKeyStore()
        )
        let window = TrivaRootCoordinator(engine: .cloudBYOK, stores: stores, windowRegistry: WindowConversationRegistry())

        let outcome = window.apply(.notice(.sharesDropped(2)))

        #expect(outcome == .noticeShown)
        let controller = try #require(window.session.chatViewModel).attachmentController
        #expect(controller.notices.map(\.message) == ["2 partages plus anciens n'ont pas pu être gardés."])
        #expect(controller.attachments.isEmpty)
        #expect(window.session.draft.text.isEmpty)
    }
}

private struct OverflowKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}
