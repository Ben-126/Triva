//
//  MacPasteboardReaderTests.swift
//  TrivaTests
//
//  K2 (Mac) : lecture d'un VRAI `NSPasteboard` (un presse-papiers nommé et jetable : jamais le presse-papiers de
//  l'utilisateur) puis classement et copie dans les dépôts. Seul Cmd+V dans la fenêtre n'est pas testé ici : aucun
//  pilotage d'interface.
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Collage Mac — lecture du presse-papiers")
struct MacPasteboardReaderTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("TrivaTests-K2-\(UUID().uuidString)"))
    }

    private func withTempFile<T>(_ name: String, _ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacPaste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data("contenu".utf8).write(to: url)
        return try await body(url)
    }

    @Test("Copie du Finder (adresse de fichier + nom en texte) : classée « fichier », le texte n'est pas collé")
    func finderCopy() async throws {
        try await withTempFile("rapport.pdf") { url in
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            pasteboard.setString("rapport.pdf", forType: .string)

            let payload = MacPastePayload.read(from: pasteboard)
            #expect(PasteboardClassifier.decision(for: payload.snapshot) == .files)
            #expect(payload.fileURLs.map(\.lastPathComponent) == ["rapport.pdf"])
            #expect(payload.imageData == nil)
        }
    }

    @Test("Texte seul : collage de texte normal, aucun fichier ni image lus")
    func plainText() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Capitale du Japon ?", forType: .string)
        let payload = MacPastePayload.read(from: pasteboard)
        #expect(PasteboardClassifier.decision(for: payload.snapshot) == .text)
        #expect(payload.fileURLs.isEmpty)
        #expect(payload.imageData == nil)
    }

    @Test("Capture d'écran (PNG seul) : classée « image », format PNG")
    func screenshot() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data("png".utf8), forType: .png)
        let payload = MacPastePayload.read(from: pasteboard)
        #expect(PasteboardClassifier.decision(for: payload.snapshot) == .image)
        #expect(payload.imageFormat?.fileExtension == "png")
    }

    @Test("Cellule de tableur (texte + image) : le texte gagne")
    func spreadsheetCell() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("12,5", forType: .string)
        pasteboard.setData(Data("tiff".utf8), forType: .tiff)
        #expect(PasteboardClassifier.decision(for: MacPastePayload.read(from: pasteboard).snapshot) == .text)
    }

    @Test("Presse-papiers vide : rien")
    func empty() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(PasteboardClassifier.decision(for: MacPastePayload.read(from: pasteboard).snapshot) == .nothing)
    }

    @Test("Octets d'un ancien .doc sans adresse de fichier (pièce jointe de mail) : refus expliqué, pas « rien »")
    func legacyWordWithoutAddress() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([0xD0, 0xCF, 0x11, 0xE0]), forType: NSPasteboard.PasteboardType("com.microsoft.word.doc"))
        #expect(PasteboardClassifier.decision(for: MacPastePayload.read(from: pasteboard).snapshot) == .unsupportedFile)
    }

    @Test("Le texte copié avec un fichier d'un autre genre reste un collage de texte ordinaire")
    func textBeatsForeignBytes() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([0xD0, 0xCF, 0x11, 0xE0]), forType: NSPasteboard.PasteboardType("com.microsoft.word.doc"))
        pasteboard.setString("une phrase", forType: .string)
        #expect(PasteboardClassifier.decision(for: MacPastePayload.read(from: pasteboard).snapshot) == .text)
    }

    @Test("Une image collée est copiée dans les dépôts sous un nom unique « Image collée … », lue comme une image")
    func imageIsStaged() async throws {
        var payload = MacPastePayload()
        payload.imageData = Data("png".utf8)
        payload.imageFormat = PastedImageFormat.all[0]
        let items = await payload.attachableItems()
        defer { items.forEach(Self.cleanUp) }
        guard case .image(let url) = try #require(items.first) else {
            Issue.record("attendu .image, reçu \(items)")
            return
        }
        #expect(url.lastPathComponent.hasPrefix("Image collée "))
        #expect(url.pathExtension == "png")
        #expect(url.path.contains("/\(AttachmentFileVault.depositsFolderName)/"))
        #expect(AttachmentKind(fileName: url.lastPathComponent) == .image)
    }

    @Test("Un fichier copié passe par le chemin du dépôt : un ancien .doc est refusé avec le message habituel")
    func legacyWordIsRefused() async throws {
        try await withTempFile("lettre.doc") { url in
            var payload = MacPastePayload()
            payload.fileURLs = [url]
            let items = await payload.attachableItems()
            #expect(items == [.refused(.unsupportedType)])
        }
    }

    @Test("Un PDF copié est copié dans les dépôts, nom d'origine gardé")
    func pdfIsStaged() async throws {
        try await withTempFile("rapport.pdf") { url in
            var payload = MacPastePayload()
            payload.fileURLs = [url]
            let items = await payload.attachableItems()
            defer { items.forEach(Self.cleanUp) }
            guard case .attachment(let staged) = try #require(items.first) else {
                Issue.record("attendu .attachment, reçu \(items)")
                return
            }
            #expect(staged.lastPathComponent == "rapport.pdf")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private static func cleanUp(_ item: DroppedItem) {
        switch item {
        case .attachment(let url), .image(let url): AttachmentFileVault.discardDeposit(url)
        default: break
        }
    }
}
#endif
