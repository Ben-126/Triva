//
//  SystemX1InboxTests.swift
//  TrivaTests
//
//  Mission X1 : boîte de partage (effacement vérifié, manifeste borné, nom ré-assaini, sauvegarde exclue), reprise
//  (entrée gardée jusqu'à l'application de la route, copie ratée annoncée), « Tout effacer » et routeur.
//  Tout est dans des dossiers temporaires : jamais le vrai App Group.
//

import Foundation
import Testing
@testable import Triva

private struct InboxRig {
    let root: URL
    let inboxDirectory: URL
    let depositRoot: URL
    let clock = TestClock()

    var inbox: SharedInbox {
        let clock = clock
        return SharedInbox(directory: inboxDirectory, now: { clock.date })
    }

    /// - Parameter brokenVault: la racine des dépôts est un FICHIER : toute copie de fichier échoue.
    init(brokenVault: Bool = false) throws {
        root = try TestFiles.makeFolder("x1inbox")
        inboxDirectory = root.appendingPathComponent("share-inbox", isDirectory: true)
        if brokenVault {
            depositRoot = try TestFiles.write(Data("pas un dossier".utf8), named: "vault", in: root)
        } else {
            depositRoot = root.appendingPathComponent("vault", isDirectory: true)
        }
    }

    func cleanUp() {
        // Rend le dossier modifiable avant de le supprimer (tests de permissions).
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inboxDirectory.path)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func addPDF(text: String? = nil, name: String = "Cours.pdf") throws -> SharedInboxEntry {
        let source = try TestFiles.write(SampleBytes.pdf(padding: 200), named: "src-\(UUID().uuidString).pdf", in: root)
        defer { try? FileManager.default.removeItem(at: source) }
        return try inbox.add(text: text, fileAt: source, displayName: name)
    }

    func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory.path)) ?? []
    }
}

@Suite("X1 : boîte de partage")
struct SystemX1SharedInboxTests {
    @Test("removeAll : vrai quand le dossier n'existe pas, vrai après un vrai effacement")
    func removeAllSucceeds() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        #expect(rig.inbox.removeAll())
        try rig.addPDF(text: "t")
        #expect(!rig.leftovers().isEmpty)
        #expect(rig.inbox.removeAll())
        #expect(rig.leftovers().isEmpty)
    }

    @Test("removeAll : faux quand la suppression est refusée (un fichier reste), jamais « tout est effacé »")
    func removeAllReportsFailure() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.addPDF(text: "privé")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.inboxDirectory.path)
        #expect(!rig.inbox.removeAll())
        #expect(!rig.leftovers().isEmpty)
    }

    @Test("Manifeste énorme : ignoré et effacé, jamais lu en entier")
    func oversizedManifestIsIgnored() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        let entry = try rig.addPDF(text: "t")
        let manifest = rig.inboxDirectory.appendingPathComponent("\(entry.id.uuidString).json")
        try Data(repeating: 0x20, count: SharedInbox.maxManifestByteCount + 1).write(to: manifest)
        #expect(rig.inbox.validEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("Manifeste qui est un lien symbolique : ignoré (la cible n'est pas lue)")
    func symlinkManifestIsIgnored() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        let entry = try rig.addPDF(text: "t")
        let manifest = rig.inboxDirectory.appendingPathComponent("\(entry.id.uuidString).json")
        let real = try TestFiles.write(try Data(contentsOf: manifest), named: "ailleurs.json", in: rig.root)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: real)
        #expect(rig.inbox.validEntries().isEmpty)
    }

    @Test("Nom de fichier trompeur dans le manifeste : ré-assaini à la lecture")
    func displayNameIsSanitizedOnRead() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        let entry = try rig.addPDF(text: nil, name: "Cours.pdf")
        let manifest = rig.inboxDirectory.appendingPathComponent("\(entry.id.uuidString).json")
        var json = try String(contentsOf: manifest, encoding: .utf8)
        json = json.replacingOccurrences(of: "Cours.pdf", with: "..\\/..\\/etc\\/passwd\\u202Egpj.pdf")
        try Data(json.utf8).write(to: manifest)
        let read = try #require(rig.inbox.validEntries().first)
        let name = try #require(read.file?.displayName)
        #expect(!name.contains("/") && !name.contains("\u{202E}") && !name.contains(".."))
        #expect(name.hasSuffix(".pdf"))
    }

    @Test("La boîte est exclue des sauvegardes")
    func inboxExcludedFromBackup() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.addPDF(text: "t")
        let values = try rig.inboxDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Le dossier de l'instantané du widget est exclu des sauvegardes")
    func appGroupFolderExcludedFromBackup() throws {
        let folder = try TestFiles.makeFolder("x1backup"); defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppGroupFileStore(directory: folder.appendingPathComponent("TrivaShared", isDirectory: true))
        try store.write(Data("{}".utf8), to: "x.json")
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Texte de plus de 2 000 caractères : l'entrée dit qu'il a été coupé, et le garde après relecture")
    func truncationIsRecorded() throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        let entry = try rig.inbox.add(text: String(repeating: "a", count: 3_000), fileAt: nil, displayName: nil)
        #expect(entry.textWasTruncated == true)
        #expect(rig.inbox.validEntries().first?.textWasTruncated == true)
        let short = try rig.inbox.add(text: "court", fileAt: nil, displayName: nil)
        #expect(short.textWasTruncated == nil)
    }
}

@Suite("X1 : reprise du partage")
struct SystemX1HandoffTests {
    @Test("Copie du fichier ratée : l'entrée reste dans la boîte, la reprise le dit, rien n'est effacé")
    func failedCopyKeepsTheEntry() async throws {
        let rig = try InboxRig(brokenVault: true); defer { rig.cleanUp() }
        try rig.addPDF(text: nil)
        let handoff = try #require(await SharedInboxHandoff.takeAll(from: rig.inbox, depositRoot: rig.depositRoot).first)
        #expect(handoff.fileCopyFailed)
        #expect(handoff.depositURL == nil)
        #expect(rig.inbox.validEntries().count == 1)
    }

    @Test("Copie ratée : tous les partages sont rendus, aucun n'est effacé avant la prise de route")
    func failedCopyKeepsEveryEntry() async throws {
        let rig = try InboxRig(brokenVault: true); defer { rig.cleanUp() }
        try rig.addPDF(text: "ancien", name: "a.pdf")
        rig.clock.advance(5)
        try rig.addPDF(text: "récent", name: "b.pdf")
        let handoffs = await SharedInboxHandoff.takeAll(from: rig.inbox, depositRoot: rig.depositRoot)
        #expect(handoffs.map(\.text) == ["ancien", "récent"])
        #expect(handoffs.allSatisfy { $0.fileCopyFailed })
        #expect(rig.inbox.validEntries().count == 2)
    }

    @Test("Une entrée déjà prise en charge (skipping) n'est pas reprise une seconde fois")
    func skippingEntry() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        let entry = try rig.inbox.add(text: "une fois", fileAt: nil, displayName: nil)
        #expect(await SharedInboxHandoff.takeAll(from: rig.inbox, depositRoot: rig.depositRoot, skipping: [entry.id]).isEmpty)
        #expect(await SharedInboxHandoff.takeAll(from: rig.inbox, depositRoot: rig.depositRoot).count == 1)
    }

    @Test("Texte coupé : la reprise le signale")
    func truncationIsReported() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.inbox.add(text: String(repeating: "b", count: 2_500), fileAt: nil, displayName: nil)
        let handoff = try #require(await SharedInboxHandoff.takeAll(from: rig.inbox, depositRoot: rig.depositRoot).first)
        #expect(handoff.textWasTruncated)
    }
}

@MainActor
@Suite("X1 : consommateur et routeur")
struct SystemX1ConsumerTests {
    private func makeConsumer(_ rig: InboxRig) -> (SharedInboxConsumer, SystemRouteCenter) {
        let center = SystemRouteCenter(windowLauncher: nil, depositRoot: rig.depositRoot)
        return (SharedInboxConsumer(inbox: rig.inbox, center: center, depositRoot: rig.depositRoot), center)
    }

    @Test("L'entrée reste dans l'App Group tant qu'aucune fenêtre n'a pris la route, puis part")
    func entryStaysUntilDrained() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.addPDF(text: "Résume")
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        #expect(rig.inbox.validEntries().count == 1, "app tuée ici : le partage n'est pas perdu")
        await consumer.takeOver()
        #expect(center.drain().count == 2, "deux routes (fichier, brouillon), pas quatre : jamais deux fois la même entrée")
        #expect(rig.leftovers().isEmpty)
    }

    @Test("Copie ratée avec un texte : texte livré, fichier annoncé, entrée effacée (pas de répétition)")
    func failedCopyWithText() async throws {
        let rig = try InboxRig(brokenVault: true); defer { rig.cleanUp() }
        try rig.addPDF(text: "Question")
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        #expect(center.drain() == [.draft("Question"), .notice(.fileNotCopied)])
        #expect(rig.leftovers().isEmpty)
    }

    @Test("Copie ratée d'un fichier seul : annonce UNE fois, entrée gardée pour un nouvel essai au prochain lancement")
    func failedCopyFileOnly() async throws {
        let rig = try InboxRig(brokenVault: true); defer { rig.cleanUp() }
        try rig.addPDF(text: nil)
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        await consumer.takeOver()
        #expect(center.drain() == [.notice(.fileNotCopied)])
        #expect(rig.inbox.validEntries().count == 1)
    }

    @Test("Texte coupé : une information « texte coupé » suit le brouillon")
    func truncationNotice() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.inbox.add(text: String(repeating: "c", count: 2_600), fileAt: nil, displayName: nil)
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        let routes = center.drain()
        #expect(routes.count == 2)
        #expect(routes.last == .notice(.truncatedText))
    }

    private func attachmentNames(_ routes: [SystemRoute]) -> [String] {
        routes.compactMap { if case .attachment(let url) = $0 { url.lastPathComponent } else { nil } }
    }

    @Test("Plusieurs partages avant l'ouverture : tous repris, fichiers d'abord puis textes, dans l'ordre d'arrivée")
    func severalSharesAllTaken() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.addPDF(text: "A", name: "a.pdf")
        rig.clock.advance(1)
        try rig.inbox.add(text: "B", fileAt: nil, displayName: nil)
        rig.clock.advance(1)
        try rig.addPDF(text: "C", name: "c.pdf")
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        #expect(rig.inbox.validEntries().count == 3, "app tuée ici : aucun partage n'est perdu")
        let routes = center.drain()
        #expect(attachmentNames(routes) == ["a.pdf", "c.pdf"])
        #expect(routes.suffix(3) == [.draft("A"), .draft("B"), .draft("C")])
        #expect(routes.count == 5)
        #expect(rig.leftovers().isEmpty, "les copies de l'App Group sont effacées dès que les routes sont prises")
    }

    @Test("Huit partages avec fichier, texte et un texte coupé : aucune route n'est évincée de la file")
    func eightSharesFitTheQueue() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        for index in 1...8 {
            let text = index == 3 ? String(repeating: "x", count: 2_600) : "texte \(index)"
            try rig.addPDF(text: text, name: "f\(index).pdf")
            rig.clock.advance(1)
        }
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        let routes = center.drain()
        #expect(attachmentNames(routes) == (1...8).map { "f\($0).pdf" })
        #expect(routes.filter { if case .draft = $0 { true } else { false } }.count == 8)
        #expect(routes.last == .notice(.truncatedText))
        #expect(routes.count == 17)
        #expect(rig.leftovers().isEmpty)
        let deposits = rig.depositRoot.appendingPathComponent("_deposits")
        #expect(try FileManager.default.contentsOfDirectory(atPath: deposits.path).count == 8, "aucun fichier évincé n'a été effacé")
    }

    @Test("Plusieurs textes coupés ou fichiers non copiés : chaque information n'est donnée qu'une fois")
    func noticesAreDeduplicated() async throws {
        let rig = try InboxRig(brokenVault: true); defer { rig.cleanUp() }
        for _ in 1...2 {
            try rig.addPDF(text: String(repeating: "y", count: 2_600))
            rig.clock.advance(1)
        }
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        let routes = center.drain()
        #expect(routes.filter { $0 == .notice(.truncatedText) }.count == 1)
        #expect(routes.filter { $0 == .notice(.fileNotCopied) }.count == 1)
        #expect(routes.count == 4, "deux brouillons et deux informations")
        #expect(rig.leftovers().isEmpty)
    }

    @Test("Un partage dont la copie rate n'empêche pas les autres ; celui sans texte reste pour un nouvel essai")
    func oneFailedCopyDoesNotBlockTheOthers() async throws {
        let rig = try InboxRig(brokenVault: true); defer { rig.cleanUp() }
        try rig.addPDF(text: nil, name: "seul.pdf")
        rig.clock.advance(1)
        try rig.inbox.add(text: "autre", fileAt: nil, displayName: nil)
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        await consumer.takeOver()
        #expect(center.drain() == [.draft("autre"), .notice(.fileNotCopied)])
        #expect(rig.inbox.validEntries().count == 1, "le fichier seul, non copié, reste (24 h)")
    }

    @Test("Un nouveau partage arrivé entre deux reprises est repris seul, les précédents ne reviennent pas")
    func laterShareIsTakenAlone() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.inbox.add(text: "un", fileAt: nil, displayName: nil)
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        rig.clock.advance(1)
        try rig.inbox.add(text: "deux", fileAt: nil, displayName: nil)
        await consumer.takeOver()
        #expect(center.drain() == [.draft("un"), .draft("deux")])
        await consumer.takeOver()
        #expect(center.drain().isEmpty)
    }

    @Test("« Tout effacer » : ce qui attendait une fenêtre est jeté avec son fichier, et rien ne revient")
    func eraseDiscardsPendingRoutes() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.addPDF(text: "privé")
        let (consumer, center) = makeConsumer(rig)
        await consumer.takeOver()
        #expect(consumer.eraseAll())
        #expect(center.drain().isEmpty)
        #expect(rig.leftovers().isEmpty)
        let deposits = rig.depositRoot.appendingPathComponent("_deposits")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: deposits.path)) ?? []).isEmpty)
    }

    @Test("« Tout effacer » : faux quand l'App Group refuse la suppression")
    func eraseReportsFailure() async throws {
        let rig = try InboxRig(); defer { rig.cleanUp() }
        try rig.addPDF(text: "privé")
        let (consumer, _) = makeConsumer(rig)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.inboxDirectory.path)
        #expect(!consumer.eraseAll())
    }

    @Test("Routeur : « quand une fenêtre a pris la route » est appelé au drain, et tout de suite pour une route jetée")
    func whenDrained() {
        let center = SystemRouteCenter(windowLauncher: nil)
        var drained = 0
        center.submit(.conversation(UUID())) { drained += 1 }
        #expect(drained == 0)
        _ = center.drain()
        #expect(drained == 1)
        center.submit(.draft("   ")) { drained += 1 }
        #expect(drained == 2, "un brouillon vide est jeté : rien à attendre")
    }

    @Test("Routeur : une route évincée de la file appelle aussi son rappel")
    func evictionCallsBack() {
        let center = SystemRouteCenter(windowLauncher: nil)
        var drained = 0
        center.submit(.conversation(UUID())) { drained += 1 }
        for _ in 0..<SystemRouteCenter.maxPending { center.submit(.conversation(UUID())) }
        #expect(drained == 1)
    }

    @Test("Mac : une conversation inconnue n'ouvre aucune fenêtre ; une connue en ouvre une")
    func macUnknownConversation() {
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)
        let known = UUID()
        center.conversationExists = { $0 == known }
        center.submit(.conversation(UUID()))
        #expect(launcher.drain().isEmpty)
        center.submit(.conversation(known))
        #expect(launcher.drain().count == 1)
    }

    @Test("Mac : un appel identique en rafale n'ouvre qu'une fenêtre ; passé le délai, il en ouvre une autre")
    func macRapidRepeat() {
        let launcher = ExternalSearchLauncher()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let center = SystemRouteCenter(windowLauncher: launcher, now: { date })
        for _ in 0..<5 { center.submit(.newQuestion(.keyboard)) }
        #expect(launcher.drain().count == 1)
        date.addTimeInterval(SystemRouteCenter.repeatWindow + 0.1)
        center.submit(.newQuestion(.keyboard))
        #expect(launcher.drain().count == 1)
    }

    @Test("Mac : deux conversations différentes de suite ouvrent chacune leur fenêtre")
    func macDifferentConversations() {
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)
        center.submit(.conversation(UUID()))
        center.submit(.conversation(UUID()))
        #expect(launcher.drain().count == 2)
    }

    @Test("Les informations du partage ne s'écrivent pas en URL triva://")
    func noURLForNotice() {
        #expect(TrivaURLRoute.url(for: .notice(.truncatedText)) == nil)
    }
}
