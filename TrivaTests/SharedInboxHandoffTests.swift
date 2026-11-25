//
//  SharedInboxHandoffTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) puis mission P : la reprise par l'app. TOUS les partages en attente (8 au plus) passent
//  dans les dépôts de l'app, dans l'ordre d'arrivée ; la copie de l'App Group de chacun est effacée une fois sa route
//  prise. Rien n'est envoyé : la reprise ne rend que du texte pour la barre de saisie et des fichiers à joindre.
//

import Foundation
import Testing
@testable import Triva

private struct HandoffFixture {
    let root: URL
    let depositRoot: URL
    let inboxDirectory: URL
    let clock = TestClock()
    var inbox: SharedInbox {
        let clock = clock
        return SharedInbox(directory: inboxDirectory, now: { clock.date })
    }

    init() throws {
        root = try TestFiles.makeFolder("handoff")
        depositRoot = root.appendingPathComponent("vault", isDirectory: true)
        inboxDirectory = root.appendingPathComponent("share-inbox", isDirectory: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func addPDF(text: String? = nil, name: String = "Cours.pdf", bytes: Data = SampleBytes.pdf(padding: 300)) throws -> SharedInboxEntry {
        let source = try TestFiles.write(bytes, named: "src-\(UUID().uuidString).pdf", in: root)
        defer { try? FileManager.default.removeItem(at: source) }
        return try inbox.add(text: text, fileAt: source, displayName: name)
    }

    func inboxLeftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory.path)) ?? [])
    }
}

@Suite("Partage — reprise par l'app")
struct SharedInboxHandoffTests {
    @Test("Boîte vide : rien à reprendre")
    func emptyInbox() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        #expect(await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot).isEmpty)
    }

    @Test("Un texte : rendu tel quel, entrée effacée, consommé UNE seule fois")
    func textOnly() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        try fixture.inbox.add(text: "Pourquoi le ciel est bleu ?", fileAt: nil, displayName: nil)
        let handoffs = await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot)
        let taken = try #require(handoffs.first)
        #expect(handoffs.count == 1)
        #expect(taken.text == "Pourquoi le ciel est bleu ?")
        #expect(taken.depositURL == nil)
        #expect(!taken.textWasTruncated && !taken.fileCopyFailed)
        // L'entrée reste dans l'App Group tant que l'app n'a pas pris la route (`commit`).
        #expect(!fixture.inboxLeftovers().isEmpty)
        SharedInboxHandoff.commit(taken.entryID, in: fixture.inbox)
        #expect(fixture.inboxLeftovers().isEmpty)
        #expect(await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot).isEmpty)
    }

    @Test("Un fichier : copié dans les dépôts de l'app sous son nom assaini, copie de l'App Group effacée dès la reprise")
    func fileMovesToDeposits() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        let bytes = SampleBytes.pdf(padding: 777)
        _ = try fixture.addPDF(text: "Résume", name: "Cours.pdf", bytes: bytes)

        let handoff = try #require(await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot).first)
        #expect(handoff.text == "Résume")
        let deposit = try #require(handoff.depositURL)
        #expect(deposit.lastPathComponent == "Cours.pdf")
        #expect(deposit.standardizedFileURL.path.hasPrefix(fixture.depositRoot.standardizedFileURL.path + "/_deposits/"))
        #expect(try Data(contentsOf: deposit) == bytes)
        SharedInboxHandoff.commit(handoff.entryID, in: fixture.inbox)
        #expect(fixture.inboxLeftovers().isEmpty, "la copie de l'App Group est effacée une fois la route prise")
    }

    @Test("Trois partages de suite : tous repris, dans l'ordre d'arrivée, chacun effacé quand sa route est prise")
    func severalSharesInArrivalOrder() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        _ = try fixture.addPDF(text: "premier", name: "un.pdf")
        fixture.clock.advance(5)
        _ = try fixture.addPDF(text: "deuxième", name: "deux.pdf")
        fixture.clock.advance(5)
        try fixture.inbox.add(text: "troisième", fileAt: nil, displayName: nil)

        let handoffs = await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot)
        #expect(handoffs.map(\.text) == ["premier", "deuxième", "troisième"])
        #expect(handoffs.map { $0.depositURL?.lastPathComponent } == ["un.pdf", "deux.pdf", nil])
        // Rien n'est effacé avant la prise de route de chaque entrée.
        #expect(fixture.inbox.validEntries().count == 3)
        SharedInboxHandoff.commit(handoffs[0].entryID, in: fixture.inbox)
        #expect(fixture.inbox.validEntries().map(\.text) == ["troisième", "deuxième"])
        handoffs.dropFirst().forEach { SharedInboxHandoff.commit($0.entryID, in: fixture.inbox) }
        #expect(fixture.inboxLeftovers().isEmpty)
        let deposits = fixture.depositRoot.appendingPathComponent("_deposits")
        #expect(try FileManager.default.contentsOfDirectory(atPath: deposits.path).count == 2)
    }

    @Test("Huit partages au plus : au-delà, la boîte ne garde que les plus récents, tous repris dans l'ordre")
    func atMostEightShares() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        for index in 1...10 {
            try fixture.inbox.add(text: "partage \(index)", fileAt: nil, displayName: nil)
            fixture.clock.advance(1)
        }
        let handoffs = await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot)
        #expect(handoffs.map(\.text) == (3...10).map { "partage \($0)" })
    }

    @Test("Deux fichiers de même nom dans deux partages : ni l'un ni l'autre n'est perdu, les noms diffèrent")
    func sameFileNameTwice() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        let first = SampleBytes.pdf(padding: 111)
        let second = SampleBytes.pdf(padding: 222)
        _ = try fixture.addPDF(name: "Cours.pdf", bytes: first)
        fixture.clock.advance(1)
        _ = try fixture.addPDF(name: "cours.PDF", bytes: second)
        fixture.clock.advance(1)
        _ = try fixture.addPDF(name: "Cours.pdf", bytes: SampleBytes.pdf(padding: 333))

        let handoffs = await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot)
        let urls = try handoffs.map { try #require($0.depositURL) }
        let names = urls.map { $0.lastPathComponent.lowercased() }
        #expect(Set(names).count == 3, "trois noms distincts (la comparaison ignore la casse)")
        #expect(urls[0].lastPathComponent == "Cours.pdf", "le premier garde son nom")
        #expect(urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" })
        #expect(try Data(contentsOf: urls[0]) == first)
        #expect(try Data(contentsOf: urls[1]) == second)
    }

    @Test("Un partage abîmé ou expiré au milieu des autres : ignoré et effacé, les autres sont repris")
    func damagedOrExpiredIsSkipped() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        _ = try fixture.addPDF(text: "expiré", name: "vieux.pdf")
        fixture.clock.advance(SharedInbox.maxAge - 20)
        _ = try fixture.addPDF(text: "bon un", name: "un.pdf")
        fixture.clock.advance(5)
        let damaged = try fixture.addPDF(text: "abîmé", bytes: SampleBytes.pdf(padding: 121))
        fixture.clock.advance(5)
        try fixture.inbox.add(text: "bon deux", fileAt: nil, displayName: nil)
        // Abîmé APRÈS les ajouts (un ajout fait déjà le ménage) : c'est la reprise qui doit l'écarter.
        try SampleBytes.executable().write(to: fixture.inbox.payloadURL(of: damaged))
        fixture.clock.advance(11)   // le premier a maintenant plus de 24 h

        let handoffs = await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot)
        #expect(handoffs.map(\.text) == ["bon un", "bon deux"])
        handoffs.forEach { SharedInboxHandoff.commit($0.entryID, in: fixture.inbox) }
        #expect(fixture.inboxLeftovers().isEmpty, "l'expiré et l'abîmé sont effacés aussi")
    }

    @Test("Entrée expirée : jamais reprise")
    func expiredIsNeverTaken() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        _ = try fixture.addPDF(text: "vieux")
        fixture.clock.advance(SharedInbox.maxAge + 1)
        #expect(await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot).isEmpty)
        #expect(fixture.inboxLeftovers().isEmpty)
    }

    @Test("Fichier malveillant glissé après coup dans l'App Group : refusé, rien ne passe dans l'app")
    func tamperedPayloadIsRefused() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        let entry = try fixture.addPDF(text: nil, bytes: SampleBytes.pdf(padding: 121))
        try SampleBytes.executable().write(to: fixture.inbox.payloadURL(of: entry))
        #expect(await SharedInboxHandoff.takeAll(from: fixture.inbox, depositRoot: fixture.depositRoot).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.depositRoot.path))
        #expect(fixture.inboxLeftovers().isEmpty)
    }

    @Test("Noms uniques : premier inchangé, casse ignorée, numéro avant l'extension, jamais deux fois le même")
    func uniqueNames() {
        var taken = Set<String>()
        #expect(SharedInboxHandoff.uniqueName("Cours.pdf", among: &taken) == "Cours.pdf")
        #expect(SharedInboxHandoff.uniqueName("COURS.pdf", among: &taken) == "COURS (2).pdf")
        #expect(SharedInboxHandoff.uniqueName("Cours.pdf", among: &taken) == "Cours (3).pdf")
        #expect(SharedInboxHandoff.uniqueName("Cours (2).pdf", among: &taken) == "Cours (2) (2).pdf")
        #expect(SharedInboxHandoff.uniqueName("Notes", among: &taken) == "Notes")
        #expect(SharedInboxHandoff.uniqueName("Notes", among: &taken) == "Notes (2)")
        #expect(SharedInboxHandoff.uniqueName("a.tar.gz", among: &taken) == "a.tar.gz")
        #expect(SharedInboxHandoff.uniqueName("a.tar.gz", among: &taken) == "a.tar (2).gz")
    }
}
