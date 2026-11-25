//
//  SharedInboxHandoffTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : la reprise par l'app. Le plus récent passe dans les dépôts de l'app, la copie de
//  l'App Group est effacée aussitôt, les autres entrées aussi. Rien n'est envoyé : la reprise ne rend que du
//  texte pour la barre de saisie et un fichier à joindre.
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
        #expect(await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot) == nil)
    }

    @Test("Un texte : rendu tel quel, entrée effacée, consommé UNE seule fois")
    func textOnly() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        try fixture.inbox.add(text: "Pourquoi le ciel est bleu ?", fileAt: nil, displayName: nil)
        let handoff = await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot)
        let taken = try #require(handoff)
        #expect(taken.text == "Pourquoi le ciel est bleu ?")
        #expect(taken.depositURL == nil)
        #expect(!taken.textWasTruncated && !taken.fileCopyFailed)
        // L'entrée reste dans l'App Group tant que l'app n'a pas pris la route (`commit`).
        #expect(!fixture.inboxLeftovers().isEmpty)
        SharedInboxHandoff.commit(taken.entryID, in: fixture.inbox)
        #expect(fixture.inboxLeftovers().isEmpty)
        #expect(await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot) == nil)
    }

    @Test("Un fichier : copié dans les dépôts de l'app sous son nom assaini, copie de l'App Group effacée dès la reprise")
    func fileMovesToDeposits() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        let bytes = SampleBytes.pdf(padding: 777)
        _ = try fixture.addPDF(text: "Résume", name: "Cours.pdf", bytes: bytes)

        let handoff = try #require(await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot))
        #expect(handoff.text == "Résume")
        let deposit = try #require(handoff.depositURL)
        #expect(deposit.lastPathComponent == "Cours.pdf")
        #expect(deposit.standardizedFileURL.path.hasPrefix(fixture.depositRoot.standardizedFileURL.path + "/_deposits/"))
        #expect(try Data(contentsOf: deposit) == bytes)
        SharedInboxHandoff.commit(handoff.entryID, in: fixture.inbox)
        #expect(fixture.inboxLeftovers().isEmpty, "la copie de l'App Group est effacée une fois la route prise")
    }

    @Test("Deux partages de suite : le plus récent est repris, l'ancien est effacé avec son fichier")
    func twoSharesInARow() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        _ = try fixture.addPDF(text: "ancien", name: "ancien.pdf")
        fixture.clock.advance(5)
        _ = try fixture.addPDF(text: "récent", name: "recent.pdf")

        let handoff = try #require(await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot))
        #expect(handoff.text == "récent")
        #expect(handoff.depositURL?.lastPathComponent == "recent.pdf")
        SharedInboxHandoff.commit(handoff.entryID, in: fixture.inbox)
        #expect(fixture.inboxLeftovers().isEmpty)
        let deposits = fixture.depositRoot.appendingPathComponent("_deposits")
        let staged = try FileManager.default.contentsOfDirectory(atPath: deposits.path)
        #expect(staged.count == 1, "un seul fichier de l'ancien partage n'est passé dans l'app")
    }

    @Test("Entrée expirée : jamais reprise")
    func expiredIsNeverTaken() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        _ = try fixture.addPDF(text: "vieux")
        fixture.clock.advance(SharedInbox.maxAge + 1)
        #expect(await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot) == nil)
        #expect(fixture.inboxLeftovers().isEmpty)
    }

    @Test("Fichier malveillant glissé après coup dans l'App Group : refusé, rien ne passe dans l'app")
    func tamperedPayloadIsRefused() async throws {
        let fixture = try HandoffFixture(); defer { fixture.cleanUp() }
        let entry = try fixture.addPDF(text: nil, bytes: SampleBytes.pdf(padding: 121))
        try SampleBytes.executable().write(to: fixture.inbox.payloadURL(of: entry))
        #expect(await SharedInboxHandoff.takeLatest(from: fixture.inbox, depositRoot: fixture.depositRoot) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.depositRoot.path))
        #expect(fixture.inboxLeftovers().isEmpty)
    }
}
