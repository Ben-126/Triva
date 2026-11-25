//
//  DroppedItemTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M5) : ce que reçoit la fenêtre de recherche. Les fichiers et textes passent par de VRAIS
//  `NSItemProvider` (ce que SwiftUI donne à `dropDestination`), pas par des valeurs fabriquées à la main.
//

import CoreTransferable
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Triva

/// Charge un élément comme le fait une zone de dépôt.
private func receive(_ provider: NSItemProvider) async throws -> DroppedItem {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadTransferable(type: DroppedItem.self) { result in
            continuation.resume(with: result)
        }
    }
}

/// Fichier jetable : le dossier est supprimé en fin de test, ainsi que le dépôt éventuellement créé.
private func withDroppedFile<T>(_ name: String, contents: Data = Data("contenu".utf8), _ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DropTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(name)
    try contents.write(to: url)
    return try await body(url)
}

private func cleanUp(_ item: DroppedItem) {
    switch item {
    case .attachment(let url), .image(let url): AttachmentFileVault.discardDeposit(url)
    default: break
    }
}

@Suite("Dépôt — réception des éléments")
struct DroppedItemReceptionTests {
    @Test("Une adresse de fichier (Finder, Fichiers) devient une pièce jointe copiée dans les dépôts, nom d'origine gardé",
          arguments: ["rapport.pdf", "notes.txt", "lisez-moi.md", "tableau.csv", "donnees.json"])
    func fileURLsBecomeAttachments(name: String) async throws {
        try await withDroppedFile(name) { url in
            let item = DroppedItem.fromURL(url)
            defer { cleanUp(item) }
            guard case .attachment(let staged) = item else {
                Issue.record("« \(name) » aurait dû être une pièce jointe, reçu : \(item)")
                return
            }
            #expect(staged.lastPathComponent == name)
            #expect(staged != url)
            #expect(staged.path.contains("/\(AttachmentFileVault.depositsFolderName)/"))
            let text = try String(contentsOf: staged, encoding: .utf8)
            #expect(text == "contenu")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Un fichier présenté sans adresse (promesse de fichier) est aussi copié, avec la bonne extension",
          arguments: ["rapport.pdf", "tableau.csv", "donnees.json"])
    func promisedFilesAreCopied(name: String) async throws {
        try await withDroppedFile(name) { url in
            let item = try await receive(NSItemProvider(contentsOf: url)!)
            defer { cleanUp(item) }
            guard case .attachment(let staged) = item else {
                Issue.record("« \(name) » aurait dû être une pièce jointe, reçu : \(item)")
                return
            }
            #expect(staged.pathExtension == url.pathExtension)
            #expect(staged.path.contains("/\(AttachmentFileVault.depositsFolderName)/"))
            let text = try String(contentsOf: staged, encoding: .utf8)
            #expect(text == "contenu")
        }
    }

    @Test("Une image déposée est reconnue comme image (lecture locale : mission M6)")
    func imageIsRecognised() async throws {
        try await withDroppedFile("capture.png", contents: Data([0x89, 0x50, 0x4E, 0x47])) { url in
            let direct = DroppedItem.fromURL(url)
            defer { cleanUp(direct) }
            guard case .image(let staged) = direct else {
                Issue.record("reçu : \(direct)")
                return
            }
            #expect(staged.lastPathComponent == "capture.png")

            let promised = try await receive(NSItemProvider(contentsOf: url)!)
            defer { cleanUp(promised) }
            if case .image = promised {} else { Issue.record("reçu : \(promised)") }
        }
    }

    @Test("Un dessin vectoriel ou un format RAW n'est pas lu : refusé sans copie")
    func unreadableImageFormatIsRefused() async throws {
        try await withDroppedFile("logo.svg", contents: Data("<svg/>".utf8)) { url in
            #expect(DroppedItem.fromURL(url) == .refused(.unsupportedType))
        }
    }

    @Test("Un dossier ou un fichier absent n'est jamais une pièce jointe")
    func folderOrMissingFileIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dossier-\(UUID().uuidString).pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DroppedItem.fromURL(folder) == .refused(.unreadable))
        #expect(DroppedItem.fromURL(folder.appendingPathComponent("absent.pdf")) == .refused(.unreadable))
    }

    /// Le classement RÉEL (`DroppedItem.receiveFile`, par l'extension, comme l'extracteur) : ce que chaque
    /// format donne. Il remplace l'ancien `DropClassifier.classify`, code mort supprimé (mission G1).
    private enum Expected: Sendable { case attachment, image, refused }

    @Test("Chaque extension donne le bon usage : pièce jointe, image, ou refus",
          arguments: [
              ("a.pdf", Expected.attachment), ("a.txt", .attachment), ("a.md", .attachment), ("a.csv", .attachment),
              ("a.json", .attachment), ("a.docx", .attachment),
              ("a.png", .image), ("a.jpg", .image), ("a.heic", .image), ("a.gif", .image), ("a.webp", .image),
              ("a.svg", .refused), ("a.dng", .refused), ("a.zip", .refused), ("a.doc", .refused), ("a.odt", .refused), ("a.pages", .refused),
              ("a.html", .refused), ("a.mp3", .refused), ("a.rtf", .refused), ("sans-extension", .refused),
          ])
    private func extensionDecidesTheUse(name: String, expected: Expected) async throws {
        try await withDroppedFile(name) { url in
            let item = DroppedItem.fromURL(url)
            defer { cleanUp(item) }
            let actual: Expected
            switch item {
            case .attachment: actual = .attachment
            case .image: actual = .image
            default: actual = .refused
            }
            #expect(actual == expected, "\(name) : reçu \(item)")
            if actual == .refused { #expect(item == .refused(.unsupportedType), "\(name)") }
        }
    }

    @Test("Tout type que la pièce jointe sait lire (1.11 et images M6) est accepté à la réception, rien d'autre")
    func everyReadableTypeIsAccepted() async throws {
        for type in FileAttachmentRules.allowedContentTypes {
            let ext = try #require(type.preferredFilenameExtension, "\(type.identifier)")
            try await withDroppedFile("a.\(ext)") { url in
                let item = DroppedItem.fromURL(url)
                defer { cleanUp(item) }
                switch item {
                case .attachment: #expect(!type.conforms(to: .image), "\(type.identifier)")
                case .image: #expect(type.conforms(to: .image), "\(type.identifier)")
                default: Issue.record("\(type.identifier) (.\(ext)) devrait être accepté, reçu : \(item)")
                }
            }
        }
    }

    @Test("Le message de refus est une phrase fermée, sans nom de fichier")
    func refusalMessages() {
        #expect(DropRefusal.unsupportedType.message == "Triva ne lit pas ce type de fichier.")
        #expect(!DropRefusal.tooLarge.message.isEmpty)
        #expect(!DropRefusal.unreadable.message.isEmpty)
    }

    @Test("Un type que Triva ne lit pas n'est jamais une pièce jointe")
    func unknownTypeIsNotAnAttachment() async throws {
        try await withDroppedFile("archive.zip") { url in
            #expect(DroppedItem.fromURL(url) == .refused(.unsupportedType))
            do {
                let received = try await receive(NSItemProvider(contentsOf: url)!)
                defer { cleanUp(received) }
                if case .attachment = received { Issue.record("un .zip ne doit pas être joint") }
                if case .image = received { Issue.record("un .zip n'est pas une image") }
            } catch {
                // Attendu : aucune représentation de `DroppedItem` ne correspond à un .zip, le chargement échoue.
            }
        }
    }

    @Test("Un texte glissé depuis une page va dans le brouillon, pas dans les pièces jointes")
    func plainTextGoesToDraft() async throws {
        let item = try await receive(NSItemProvider(object: "Une phrase sélectionnée" as NSString))
        defer { cleanUp(item) }
        #expect(item == .text("Une phrase sélectionnée"))
    }

    @Test("Une adresse web va dans le brouillon")
    func webURLGoesToDraft() async throws {
        let url = try #require(URL(string: "https://example.org/page"))
        let item = try await receive(NSItemProvider(object: url as NSURL))
        defer { cleanUp(item) }
        #expect(item == .webURL(url))
    }

    @Test("Seules les adresses http et https sont acceptées")
    func onlyWebSchemes() throws {
        #expect(DroppedItem.fromURL(try #require(URL(string: "http://example.org"))) == .webURL(try #require(URL(string: "http://example.org"))))
        #expect(DroppedItem.fromURL(try #require(URL(string: "file:///etc/passwd"))) == .refused(.unsupportedType))
        #expect(DroppedItem.fromURL(try #require(URL(string: "mailto:a@b.fr"))) == .refused(.unsupportedType))
        #expect(DroppedItem.fromURL(try #require(URL(string: "javascript:alert(1)"))) == .refused(.unsupportedType))
    }
}

@Suite("Dépôt — plan d'application")
struct DropPlanTests {
    private let file = URL(fileURLWithPath: "/dépôts/a/notes.txt")
    private let picture = URL(fileURLWithPath: "/dépôts/b/photo.png")

    @Test("Chaque élément va à sa place, dans l'ordre")
    func sortsItems() throws {
        let web = try #require(URL(string: "https://example.org"))
        let plan = DropPlan(items: [.attachment(file), .text("  bonjour  "), .image(picture), .webURL(web), .refused(.tooLarge)])
        #expect(plan.attachmentURLs == [file])
        #expect(plan.imageURLs == [picture])
        #expect(plan.attachableURLs == [file, picture])
        #expect(plan.draftTexts == ["bonjour", "https://example.org"])
        #expect(plan.refusals == [.tooLarge])
        #expect(plan.refusalMessage == DropRefusal.tooLarge.message)
        #expect(!plan.isEmpty)
    }

    @Test("Un texte vide ou fait de blancs est refusé, pas ajouté")
    func blankTextIsRefused() {
        let plan = DropPlan(items: [.text("   \n "), .text("")])
        #expect(plan.draftTexts.isEmpty)
        #expect(plan.refusals.count == 2)
    }

    @Test("Un texte glissé est assaini comme une question venue de l'extérieur")
    func textIsSanitized() {
        let plan = DropPlan(items: [.text("a\u{0007}b\u{202E}c")])
        #expect(plan.draftTexts == ["abc"])
        let long = String(repeating: "x", count: ExternalQuerySanitizer.maxLength + 500)
        #expect(DropPlan(items: [.text(long)]).draftTexts.first?.count == ExternalQuerySanitizer.maxLength)
    }

    @Test("Aucun élément : plan vide")
    func emptyPlan() {
        #expect(DropPlan(items: []).isEmpty)
        #expect(DropPlan(items: []).refusalMessage == nil)
    }

    @Test("Les messages de refus sont fermés : aucun ne contient de nom de fichier")
    func refusalMessagesAreClosed() {
        #expect(DropRefusal.unsupportedType.message == "Triva ne lit pas ce type de fichier.")
        #expect(DropRefusal.tooLarge.message == "Ce fichier est trop volumineux pour être joint.")
        #expect(DropRefusal.unreadable.message == "Impossible de lire ce fichier.")
    }

    @Test("Ajout au brouillon : à la suite, séparé d'une espace, sans doubler les blancs")
    func appendingToDraft() {
        #expect(DropPlan.appending(["a"], to: "") == "a")
        #expect(DropPlan.appending(["a"], to: "Que") == "Que a")
        #expect(DropPlan.appending(["a"], to: "Que ") == "Que a")
        #expect(DropPlan.appending(["a", "b"], to: "") == "a b")
        #expect(DropPlan.appending([], to: "garde") == "garde")
    }

    @Test("Le survol : seules les phases entering et active allument la surbrillance")
    func hoverPhases() {
        #expect(SearchDropPresentation.isTargeted(.entering))
        #expect(SearchDropPresentation.isTargeted(.active))
        #expect(!SearchDropPresentation.isTargeted(.exiting))
        #expect(!SearchDropPresentation.isTargeted(.dataTransferCompleted))
    }
}
