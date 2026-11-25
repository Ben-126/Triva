//
//  SharedInboxTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : la boîte de partage dans l'App Group. Expiration, capacité, fichier malveillant, nom
//  piégé, entrée tronquée, deux partages de suite. Tout se passe dans un dossier temporaire et avec une horloge de test.
//

import Foundation
import Testing
@testable import Triva

/// Dossier de boîte + sources, nettoyés par `cleanUp()`.
private struct Fixture {
    let root: URL
    let inboxDirectory: URL
    let sources: URL
    let clock = TestClock()
    var inbox: SharedInbox {
        let clock = clock
        return SharedInbox(directory: inboxDirectory, now: { clock.date })
    }

    init() throws {
        root = try TestFiles.makeFolder("inbox")
        inboxDirectory = root.appendingPathComponent("share-inbox", isDirectory: true)
        sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func source(_ data: Data, named name: String) throws -> URL { try TestFiles.write(data, named: name, in: sources) }

    /// Tout ce qui est posé dans le dossier de la boîte (noms seulement).
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory.path)) ?? []).sorted()
    }

    func manifestURL(_ entry: SharedInboxEntry) -> URL { inboxDirectory.appendingPathComponent("\(entry.id.uuidString).json") }
}

@Suite("Partage — boîte de l'App Group : texte")
struct SharedInboxTextTests {
    @Test("Un texte écrit se relit, assaini")
    func textRoundTrip() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let entry = try fixture.inbox.add(text: "  Qui a peint\u{202E} la Joconde ?\t", fileAt: nil, displayName: nil)
        #expect(entry.text == "Qui a peint la Joconde ?")
        #expect(entry.file == nil)
        #expect(fixture.inbox.validEntries() == [entry])
    }

    @Test("Un texte trop long est tronqué comme toute entrée externe")
    func textIsTruncated() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let entry = try fixture.inbox.add(text: String(repeating: "a", count: 5_000), fileAt: nil, displayName: nil)
        #expect(entry.text?.count == ExternalQuerySanitizer.maxLength)
    }

    @Test("Ni texte lisible ni fichier : rien n'est écrit")
    func nothingToStore() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        for blank in [nil, "", "   \n\t", "\u{200B}\u{202E}"] {
            #expect(throws: SharedInbox.Failure.emptyContent) { try fixture.inbox.add(text: blank, fileAt: nil, displayName: nil) }
        }
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Expiration : une entrée de plus de 24 h disparaît, une de 23 h 59 reste")
    func expiry() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let old = try fixture.inbox.add(text: "ancienne", fileAt: nil, displayName: nil)
        fixture.clock.advance(SharedInbox.maxAge - 60)
        #expect(fixture.inbox.validEntries() == [old])
        fixture.clock.advance(120)
        #expect(fixture.inbox.validEntries().isEmpty)
        #expect(fixture.leftovers().isEmpty, "le manifeste expiré est effacé du disque")
    }

    @Test("Capacité : 8 entrées au plus, les plus anciennes partent avec leur fichier")
    func capacity() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let pdf = try fixture.source(SampleBytes.pdf(), named: "a.pdf")
        var added: [SharedInboxEntry] = []
        for index in 0..<10 {
            fixture.clock.advance(1)
            added.append(try fixture.inbox.add(text: "q\(index)", fileAt: index < 2 ? pdf : nil, displayName: "a.pdf"))
        }
        let kept = fixture.inbox.validEntries()
        #expect(kept.count == SharedInbox.maxEntries)
        #expect(kept.map(\.id) == added.suffix(8).reversed().map(\.id), "les 8 plus récentes, la plus récente d'abord")
        #expect(fixture.leftovers().count == 8, "aucun fichier orphelin des deux entrées évincées")
    }

    @Test("Deux partages de suite : le plus récent d'abord, chacun avec son identifiant")
    func twoSharesInARow() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let first = try fixture.inbox.add(text: "premier", fileAt: nil, displayName: nil)
        fixture.clock.advance(2)
        let second = try fixture.inbox.add(text: "second", fileAt: nil, displayName: nil)
        #expect(first.id != second.id)
        #expect(fixture.inbox.validEntries().map(\.text) == ["second", "premier"])
    }

    @Test("Tout vider : le dossier ne contient plus rien, fichiers en cours d'écriture compris")
    func removeAll() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let pdf = try fixture.source(SampleBytes.pdf(), named: "a.pdf")
        try fixture.inbox.add(text: "t", fileAt: pdf, displayName: "a.pdf")
        try fixture.inbox.add(text: "u", fileAt: nil, displayName: nil)
        try TestFiles.write(Data("en cours".utf8), named: "\(UUID().uuidString).part", in: fixture.inboxDirectory)
        fixture.inbox.removeAll()
        #expect(fixture.leftovers().isEmpty)
        #expect(fixture.inbox.validEntries().isEmpty)
        fixture.inbox.removeAll()
    }
}

@Suite("Partage — boîte de l'App Group : fichiers")
struct SharedInboxFileTests {
    @Test("Un PDF est copié octet pour octet, et le manifeste dit son type, son nom et sa taille")
    func pdfRoundTrip() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let bytes = SampleBytes.pdf(padding: 1_000)
        let source = try fixture.source(bytes, named: "Cours.pdf")
        let entry = try fixture.inbox.add(text: "Résume ce cours", fileAt: source, displayName: "Cours.pdf")
        let file = try #require(entry.file)
        #expect(file.type == .pdf)
        #expect(file.displayName == "Cours.pdf")
        #expect(file.byteCount == bytes.count)
        #expect(try Data(contentsOf: fixture.inbox.payloadURL(of: entry)) == bytes)
        #expect(FileManager.default.fileExists(atPath: source.path), "la source n'est pas déplacée : l'appelant la supprime")
        #expect(fixture.inbox.validEntries() == [entry])
    }

    @Test("Une image passe aussi ; elle porte l'extension de son vrai format")
    func imageRoundTrip() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.jpeg(), named: "IMG_1.JPEG")
        let entry = try fixture.inbox.add(text: nil, fileAt: source, displayName: "IMG_1.JPEG")
        #expect(entry.file?.type == .jpeg)
        #expect(entry.file?.displayName == "IMG_1.jpg")
        #expect(entry.text == nil)
    }

    @Test("Le nom sur le disque est un identifiant : le nom d'origine n'y figure jamais")
    func diskNameIsAnIdentifier() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.pdf(), named: "Dossier médical Léa.pdf")
        let entry = try fixture.inbox.add(text: nil, fileAt: source, displayName: "Dossier médical Léa.pdf")
        let names = fixture.leftovers()
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasPrefix(entry.id.uuidString) })
        #expect(names.allSatisfy { !$0.contains("Léa") })
    }

    // MARK: Fichier malveillant

    @Test("Fichier malveillant : un exécutable déguisé en PDF est refusé, rien ne reste")
    func maliciousExecutableNamedPDF() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.executable(), named: "facture.pdf")
        #expect(throws: SharedInbox.Failure.unsupportedFile) { try fixture.inbox.add(text: "x", fileAt: source, displayName: "facture.pdf") }
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Fichier malveillant : une image dont le nom ment est classée selon son contenu")
    func contentWinsOverName() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.png(), named: "faux.pdf")
        let entry = try fixture.inbox.add(text: nil, fileAt: source, displayName: "faux.pdf")
        #expect(entry.file?.type == .png)
        #expect(entry.file?.displayName == "faux.png")
    }

    @Test("Fichier malveillant : un lien symbolique, un dossier et un fichier vide sont refusés")
    func symlinkDirectoryEmpty() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let real = try fixture.source(SampleBytes.pdf(), named: "vrai.pdf")
        let link = fixture.sources.appendingPathComponent("lien.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let folder = fixture.sources.appendingPathComponent("dossier.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let empty = try fixture.source(Data(), named: "vide.pdf")
        for refused in [link, folder, empty] {
            #expect(throws: SharedInbox.Failure.unsupportedFile) { try fixture.inbox.add(text: nil, fileAt: refused, displayName: nil) }
        }
        #expect(throws: SharedInbox.Failure.unreadable) {
            try fixture.inbox.add(text: nil, fileAt: fixture.sources.appendingPathComponent("absent.pdf"), displayName: nil)
        }
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Plafonds : un PDF de plus de 200 Mo et une image de plus de 50 Mo sont refusés AVANT toute copie")
    func sizeCaps() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let bigPDF = try TestFiles.writeSparse(header: SampleBytes.pdf(), size: SharedFileType.pdf.maxByteCount + 1, named: "gros.pdf", in: fixture.sources)
        let bigPNG = try TestFiles.writeSparse(header: SampleBytes.png(), size: SharedFileType.png.maxByteCount + 1, named: "gros.png", in: fixture.sources)
        for big in [bigPDF, bigPNG] {
            #expect(throws: SharedInbox.Failure.tooLarge) { try fixture.inbox.add(text: nil, fileAt: big, displayName: nil) }
        }
        #expect(fixture.leftovers().isEmpty)
        let justFits = try TestFiles.writeSparse(header: SampleBytes.png(), size: SharedFileType.png.maxByteCount, named: "limite.png", in: fixture.sources)
        #expect(try fixture.inbox.add(text: nil, fileAt: justFits, displayName: nil).file?.type == .png)
    }

    @Test("Plafond total de 400 Mo : les entrées les plus anciennes sont évincées pour faire de la place")
    func totalCap() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let size = 150 * 1_024 * 1_024
        var entries: [SharedInboxEntry] = []
        for index in 0..<3 {
            fixture.clock.advance(1)
            let source = try TestFiles.writeSparse(header: SampleBytes.pdf(), size: size, named: "p\(index).pdf", in: fixture.sources)
            entries.append(try fixture.inbox.add(text: nil, fileAt: source, displayName: "p\(index).pdf"))
        }
        #expect(fixture.inbox.validEntries().map(\.id) == [entries[2].id, entries[1].id])
        #expect(fixture.leftovers().count == 4)
    }

    // MARK: Nom piégé

    @Test("Nom piégé : le nom affiché est assaini, jamais un chemin")
    func trappedDisplayName() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.pdf(), named: "x.pdf")
        let entry = try fixture.inbox.add(text: nil, fileAt: source, displayName: "../../Library/\u{202E}secret\u{0}.pdf")
        let name = try #require(entry.file?.displayName)
        #expect(!name.contains("/") && !name.contains("\0") && !name.contains("\u{202E}"))
        #expect(name.hasSuffix(".pdf"))
        #expect(fixture.leftovers().allSatisfy { !$0.contains("secret") })
    }

    // MARK: Entrée tronquée

    @Test("Entrée tronquée : un manifeste coupé en deux est ignoré puis effacé, avec son fichier")
    func truncatedManifest() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.pdf(), named: "a.pdf")
        let entry = try fixture.inbox.add(text: "q", fileAt: source, displayName: "a.pdf")
        let manifest = try Data(contentsOf: fixture.manifestURL(entry))
        try manifest.prefix(manifest.count / 2).write(to: fixture.manifestURL(entry))
        #expect(fixture.inbox.validEntries().isEmpty)
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Entrée tronquée : fichier plus court que prévu, ou absent, l'entrée entière est effacée")
    func truncatedPayload() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.pdf(padding: 500), named: "a.pdf")
        let shortened = try fixture.inbox.add(text: nil, fileAt: source, displayName: "a.pdf")
        try Data(contentsOf: fixture.inbox.payloadURL(of: shortened)).prefix(100).write(to: fixture.inbox.payloadURL(of: shortened))
        fixture.clock.advance(1)
        let missing = try fixture.inbox.add(text: "avec texte", fileAt: source, displayName: "a.pdf")
        try FileManager.default.removeItem(at: fixture.inbox.payloadURL(of: missing))
        #expect(fixture.inbox.validEntries().isEmpty)
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Entrée tronquée : un fichier remplacé après coup par un exécutable de même taille est refusé")
    func payloadSwappedAfterWrite() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let source = try fixture.source(SampleBytes.pdf(padding: 121), named: "a.pdf")
        let entry = try fixture.inbox.add(text: nil, fileAt: source, displayName: "a.pdf")
        let swapped = SampleBytes.executable()
        #expect(swapped.count == entry.file?.byteCount)
        try swapped.write(to: fixture.inbox.payloadURL(of: entry))
        #expect(fixture.inbox.validEntries().isEmpty)
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Entrée tronquée : fichier sans manifeste (écriture en cours) gardé 10 min, puis effacé")
    func orphanPayload() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.inboxDirectory, withIntermediateDirectories: true)
        let orphan = fixture.inboxDirectory.appendingPathComponent("\(UUID().uuidString).payload")
        let part = fixture.inboxDirectory.appendingPathComponent("\(UUID().uuidString).part")
        for url in [orphan, part] { try SampleBytes.pdf().write(to: url) }
        let fileDate = fixture.clock.date
        for url in [orphan, part] { try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: url.path) }

        fixture.clock.advance(SharedInbox.orphanGrace - 30)
        #expect(fixture.inbox.validEntries().isEmpty)
        #expect(fixture.leftovers().count == 2, "l'extension écrit peut-être encore")
        fixture.clock.advance(60)
        #expect(fixture.inbox.validEntries().isEmpty)
        #expect(fixture.leftovers().isEmpty)
    }

    @Test("Manifeste illisible, de version inconnue ou sans contenu : ignoré et effacé, sans plantage")
    func garbageManifests() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let good = try fixture.inbox.add(text: "bon", fileAt: nil, displayName: nil)
        try FileManager.default.createDirectory(at: fixture.inboxDirectory, withIntermediateDirectories: true)
        let garbageNames = [UUID(), UUID(), UUID()].map(\.uuidString)
        try Data("pas du JSON".utf8).write(to: fixture.inboxDirectory.appendingPathComponent("\(garbageNames[0]).json"))
        let futureVersion = #"{"version":99,"id":"\#(garbageNames[1])","createdAt":0,"text":"x"}"#
        try Data(futureVersion.utf8).write(to: fixture.inboxDirectory.appendingPathComponent("\(garbageNames[1]).json"))
        let noContent = #"{"version":1,"id":"\#(garbageNames[2])","createdAt":\#(fixture.clock.date.timeIntervalSinceReferenceDate)}"#
        try Data(noContent.utf8).write(to: fixture.inboxDirectory.appendingPathComponent("\(garbageNames[2]).json"))

        #expect(fixture.inbox.validEntries() == [good])
        #expect(fixture.leftovers() == ["\(good.id.uuidString).json"])
    }
}
