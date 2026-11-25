//
//  WordFileIntegrationTests.swift
//  TrivaTests
//
//  Mission W : les documents Word par TOUS les chemins d'ajout — sélecteur, glisser-déposer, collage, partage — et le
//  refus clair (« Triva ne lit pas ce type de fichier. ») de tout ce qui n'est pas pris en charge (ancien .doc, .docm,
//  .pages, .odt, archive…). Les éléments passent par de VRAIS `NSItemProvider`, comme ceux que donne le système.
//

import CoreTransferable
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Triva
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

private let unsupportedMessage = "Triva ne lit pas ce type de fichier."

private let wordText = ["Le Moyen Âge commence en 476.", "La chute de Rome marque la fin de l'Antiquité."]

private func wordDocument() -> Data { DocxFixture.make(paragraphs: wordText) }

/// Un fichier jetable dans son propre dossier.
@discardableResult
private func withTemporaryFile<T>(_ name: String, _ data: Data, _ body: (URL) async throws -> T) async throws -> T {
    let folder = try TestFiles.makeFolder("word")
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(try TestFiles.write(data, named: name, in: folder))
}

private func receive(_ provider: NSItemProvider) async throws -> DroppedItem {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadTransferable(type: DroppedItem.self) { result in continuation.resume(with: result) }
    }
}

private func discard(_ item: DroppedItem) {
    switch item {
    case .attachment(let url), .image(let url): AttachmentFileVault.discardDeposit(url)
    default: break
    }
}

/// Un fournisseur de FICHIER sans adresse (pièce jointe de mail, promesse de fichier) de type `identifier`.
private func filePromise(_ data: Data, named name: String, typeIdentifier: String, in folder: URL) throws -> NSItemProvider {
    let url = try TestFiles.write(data, named: name, in: folder)
    let provider = NSItemProvider()
    provider.suggestedName = (name as NSString).deletingPathExtension
    provider.registerFileRepresentation(forTypeIdentifier: typeIdentifier, fileOptions: [], visibility: .all) { completion in
        completion(url, false, nil)
        return nil
    }
    return provider
}

private let docxIdentifier = "org.openxmlformats.wordprocessingml.document"

// MARK: - Types reconnus

@Suite("Word — type de pièce jointe")
struct WordAttachmentKindTests {
    @Test("Le .docx est reconnu, casse de l'extension indifférente", arguments: ["cours.docx", "Cours.DOCX", "Mon rapport (v2).docx"])
    func recognizesDocx(fileName: String) {
        #expect(AttachmentKind(fileName: fileName) == .docx)
    }

    @Test("Ancien .doc, macros, modèle, Pages, OpenDocument, RTF, archive : refusés", arguments: [
        "cours.doc", "cours.docm", "modele.dotx", "modele.dot", "cours.pages", "cours.odt", "cours.rtf", "cours.zip", "cours.docx.exe", "docx",
    ])
    func refusesOthers(fileName: String) {
        #expect(AttachmentKind(fileName: fileName) == nil)
    }

    @Test("Le type système du .docx existe et sert d'identifiant au sélecteur")
    func docxContentTypeExists() throws {
        let type = try #require(AttachmentKind.docxType)
        #expect(type.identifier == docxIdentifier)
        #expect(SharedFileType.docxContentType == type)
        #expect(type.preferredFilenameExtension == "docx")
    }

    @Test("Chaque type de pièce jointe a une icône qui existe dans SF Symbols, y compris Word")
    func everyKindHasAnExistingSymbol() {
        for kind in AttachmentKind.allCases {
            let name = FileAttachmentPresentation.symbolName(for: kind)
            #if canImport(AppKit)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) pour \(kind)")
            #else
            #expect(UIImage(systemName: name) != nil, "\(name) pour \(kind)")
            #endif
        }
        #expect(FileAttachmentPresentation.symbolName(for: .docx) != FileAttachmentPresentation.symbolName(for: .pdf))
    }

    @Test("Messages de refus : un seul pour un type non pris en charge, partout")
    func singleUnsupportedMessage() {
        #expect(AttachmentExtractionError.unsupportedFileType(fileExtension: "doc").userFacingMessage == unsupportedMessage)
        #expect(DropRefusal.unsupportedType.message == unsupportedMessage)
        #expect(ShareMessages.unsupportedFile == unsupportedMessage)
        #expect(FileAttachmentPresentation.failureMessage(for: AttachmentExtractionError.unsupportedFileType(fileExtension: "odt")) == unsupportedMessage)
    }

    @Test("Les messages propres au Word sont fermés et distincts")
    func wordMessages() {
        let messages = [
            AttachmentExtractionError.invalidDocx, .protectedOrLegacyWord, .docxTooLarge, .noTextInDocument,
        ].map(\.userFacingMessage)
        #expect(Set(messages).count == 4)
        #expect(messages.allSatisfy { $0.contains("Word") })
    }
}

// MARK: - Extraction

@Suite("Word — extraction par l'extracteur de pièces jointes")
struct WordExtractionTests {
    private let extractor = AttachmentTextExtractor()

    @Test("Octets en mémoire : une section, sans pagination, type Word")
    func fromData() throws {
        let result = try extractor.extract(data: wordDocument(), fileName: "cours.docx")
        #expect(result.kind == .docx)
        #expect(result.pageCount == nil)
        #expect(!result.isTruncated && !result.isCopyRestricted)
        #expect(result.textEncoding == nil)
        #expect(result.sections == [ExtractedTextSection(pageNumber: nil, text: wordText.joined(separator: "\n"))])
        #expect(result.fileName == "cours.docx")
    }

    @Test("Fichier sur disque (chemin du sélecteur et du glisser-déposer)")
    func fromFile() async throws {
        try await withTemporaryFile("cours.docx", wordDocument()) { url in
            let result = try await extractor.extract(from: url)
            #expect(result.kind == .docx)
            #expect(result.characterCount == wordText.joined(separator: "\n").count)
        }
    }

    @Test("La limite de caractères de la conversation s'applique et signale la troncature")
    func characterLimit() async throws {
        let long = DocxFixture.make(paragraphs: [(1...500).map { "mot\($0)" }.joined(separator: " ")])
        try await withTemporaryFile("long.docx", long) { url in
            let result = try await extractor.extract(from: url, characterLimit: 200)
            #expect(result.isTruncated)
            #expect(result.characterCount <= 200)
        }
    }

    @Test("Le type est vérifié AVANT le contenu : un texte nommé .docx est un faux .docx, pas du texte")
    func fakeDocxIsRefusedByContent() async throws {
        try await withTemporaryFile("faux.docx", Data("Je suis du texte.".utf8)) { url in
            await #expect(throws: AttachmentExtractionError.invalidDocx) { try await extractor.extract(from: url) }
        }
    }

    @Test("Fichier .docx de zéro octet : vide")
    func emptyFile() async throws {
        try await withTemporaryFile("vide.docx", Data()) { url in
            await #expect(throws: AttachmentExtractionError.emptyFile) { try await extractor.extract(from: url) }
        }
    }

    @Test("Ancien .doc, .pages, .odt : refusés avec le message habituel, même avec un contenu de .docx")
    func otherFormatsRefused() async throws {
        for name in ["cours.doc", "cours.pages", "cours.odt", "cours.docm"] {
            try await withTemporaryFile(name, wordDocument()) { url in
                await #expect(throws: AttachmentExtractionError.unsupportedFileType(fileExtension: (name as NSString).pathExtension)) {
                    try await extractor.extract(from: url)
                }
            }
        }
    }

    @Test("Plafond de fichier : un .docx au-delà est refusé comme trop volumineux")
    func fileLimit() async throws {
        let small = AttachmentTextExtractor(docxReader: DocxTextReader(limits: .init(maxFileByteCount: 100, maxEntryByteCount: 1_000, maxDuration: .seconds(1))))
        try await withTemporaryFile("gros.docx", wordDocument()) { url in
            await #expect(throws: AttachmentExtractionError.self) { try await small.extract(from: url) }
        }
    }

    @Test("Annulation d'une lecture de .docx : CancellationError relayée, jamais « fichier illisible »")
    func cancellation() async throws {
        try await withTemporaryFile("cours.docx", wordDocument()) { url in
            let extractor = self.extractor
            let task = Task { () -> Result<ExtractedAttachment, any Error> in
                while !Task.isCancelled { await Task.yield() }
                do { return .success(try await extractor.extract(from: url)) } catch { return .failure(error) }
            }
            task.cancel()
            let result = await task.value
            #expect(throws: CancellationError.self) { try result.get() }
        }
    }

    @Test("Le coffre copie un .docx (Coup d'œil Quick Look, comme les autres fichiers) et un .doc n'est pas copié")
    func vaultKeepsPreviewCopy() async throws {
        let root = try TestFiles.makeFolder("vault")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = AttachmentFileVault(rootDirectory: root)
        try await withTemporaryFile("cours.docx", wordDocument()) { url in
            let placement = await vault.place(url, isDeposit: false)
            let stored = try #require(placement.storedURL)
            #expect(stored.lastPathComponent == "cours.docx")
            #expect(try Data(contentsOf: stored) == wordDocument())
        }
        try await withTemporaryFile("cours.doc", wordDocument()) { url in
            #expect(await vault.place(url, isDeposit: false).storedURL == nil)
        }
    }

    @Test("Un .docx a un type Quick Look reconnu par le système (aperçu comme les autres fichiers)")
    func quickLookType() throws {
        let type = try #require(UTType(filenameExtension: "docx"))
        #expect(type == AttachmentKind.docxType)
    }

    @Test("Troncature affichée pour un .docx : « Début du fichier seulement »")
    func truncationNote() {
        let chunk = AttachmentChunk(index: 0, text: "x", pageRange: nil)
        let attachment = IndexedAttachment(
            fileName: "cours.docx", kind: .docx, pageCount: nil, characterCount: 12_500,
            isTruncated: true, isCopyRestricted: false, chunks: [chunk]
        )
        #expect(FileAttachmentPresentation.truncationNote(for: attachment)?.summary == "Début du fichier seulement")
    }
}

// MARK: - Sélecteur

@Suite("Word — sélecteur de fichiers")
struct WordPickerRulesTests {
    @Test("Le sélecteur propose le .docx, et rien de plus large")
    func pickerOffersDocx() throws {
        let docx = try #require(AttachmentKind.docxType)
        #expect(FileAttachmentRules.contentTypes(for: .docx) == [docx])
        #expect(FileAttachmentRules.allowedContentTypes.contains(docx))
        #expect(FileAttachmentRules.accepts(docx))
    }

    @Test("Le sélecteur n'accepte ni l'ancien .doc, ni .docm, ni .dotx, ni .odt, ni .pages", arguments: ["doc", "docm", "dotx", "odt", "pages", "zip"])
    func pickerRefusesOthers(fileExtension: String) {
        guard let type = UTType(filenameExtension: fileExtension) else { return }
        #expect(!FileAttachmentRules.accepts(type), ".\(fileExtension) ne doit pas être proposé")
    }

    @Test("Les textes d'aide citent Word")
    func helpTexts() {
        #expect(FileAttachmentPresentation.pickerAccessibilityHint.contains("Word"))
        #expect(FileAttachmentPresentation.pickerHelpText.contains("Word"))
        #expect(FileAttachmentPresentation.dialogMessage(remainingSlots: 3).contains("Word"))
    }

    @MainActor
    @Test("Un .docx choisi dans le sélecteur est lu et joint ; un .doc est refusé avec le message habituel")
    func controllerEndToEnd() async throws {
        let folder = try TestFiles.makeFolder("picker")
        let vaultRoot = try TestFiles.makeFolder("picker-vault")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: vaultRoot) }
        let good = try TestFiles.write(wordDocument(), named: "cours.docx", in: folder)
        let old = try TestFiles.write(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 100), named: "ancien.doc", in: folder)

        let controller = FileAttachmentController(store: AttachmentStore(), vault: AttachmentFileVault(rootDirectory: vaultRoot))
        controller.handlePickerResult(.success([good, old]))

        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, !(controller.pendingAttachments.isEmpty && !controller.attachments.isEmpty && !controller.notices.isEmpty) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.attachments.map(\.fileName) == ["cours.docx"])
        #expect(controller.attachments.first?.kind == .docx)
        #expect(controller.notices.map(\.message) == [unsupportedMessage])
        #expect(controller.notices.first?.fileNames == ["ancien.doc"])
        controller.removeAll()
    }
}

// MARK: - Glisser-déposer et collage

@Suite("Word — glisser-déposer et collage (NSItemProvider)")
struct WordDropAndPasteTests {
    @Test("Une adresse de fichier .docx devient une pièce jointe copiée dans les dépôts")
    func fileURL() async throws {
        try await withTemporaryFile("cours.docx", wordDocument()) { url in
            let item = DroppedItem.fromURL(url)
            defer { discard(item) }
            guard case .attachment(let staged) = item else { Issue.record("pièce jointe attendue, reçu \(item)"); return }
            #expect(staged.lastPathComponent == "cours.docx")
            let copied = try Data(contentsOf: staged)
            #expect(copied == wordDocument())
        }
    }

    @Test("Un fichier .docx sans adresse (pièce jointe de mail, promesse de fichier) devient une pièce jointe")
    func promisedDocx() async throws {
        let folder = try TestFiles.makeFolder("promise")
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try await receive(try filePromise(wordDocument(), named: "cours.docx", typeIdentifier: docxIdentifier, in: folder))
        defer { discard(item) }
        guard case .attachment(let staged) = item else { Issue.record("pièce jointe attendue, reçu \(item)"); return }
        #expect(staged.pathExtension == "docx")
    }

    @Test("Fichiers sans adresse d'un type non pris en charge : refusés avec un message, jamais ignorés en silence",
          arguments: [
              ("ancien.doc", "com.microsoft.word.doc"),
              ("modele.dotx", "org.openxmlformats.wordprocessingml.template"),
              ("texte.odt", "org.oasis-open.opendocument.text"),
              ("texte.pages", "com.apple.iwork.pages.pages"),
              ("archive.zip", "public.zip-archive"),
              ("inconnu.xyz", "public.data"),
          ])
    func unsupportedPromises(name: String, typeIdentifier: String) async throws {
        let folder = try TestFiles.makeFolder("promise-refused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try await receive(try filePromise(wordDocument(), named: name, typeIdentifier: typeIdentifier, in: folder))
        defer { discard(item) }
        #expect(item == .refused(.unsupportedType), "« \(name) » devait être refusé, reçu \(item)")
        #expect(DropPlan(items: [item]).refusalMessage == unsupportedMessage)
    }

    @Test("Le texte glissé reste du texte : le filet « tout fichier » ne l'avale pas")
    func textStillText() async throws {
        let item = try await receive(NSItemProvider(object: "Une phrase sélectionnée" as NSString))
        #expect(item == .text("Une phrase sélectionnée"))
    }

    @Test("Un PDF sans adresse reste un PDF")
    func pdfStillPDF() async throws {
        let folder = try TestFiles.makeFolder("promise-pdf")
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try await receive(try filePromise(SampleBytes.pdf(), named: "cours.pdf", typeIdentifier: UTType.pdf.identifier, in: folder))
        defer { discard(item) }
        guard case .attachment = item else { Issue.record("pièce jointe attendue, reçu \(item)"); return }
    }

    @Test("Une adresse de fichier d'un type non pris en charge : refusée (chemin Finder, Fichiers)", arguments: ["ancien.doc", "texte.odt", "texte.pages", "archive.zip"])
    func unsupportedFileURL(name: String) async throws {
        try await withTemporaryFile(name, wordDocument()) { url in
            let item = DroppedItem.fromURL(url)
            #expect(item == .refused(.unsupportedType))
        }
    }

    @Test("Collage (iPhone, iPad, Duo) : un .docx collé devient une pièce jointe, un .doc ou .odt un refus")
    func pasteImport() async throws {
        let folder = try TestFiles.makeFolder("paste")
        defer { try? FileManager.default.removeItem(at: folder) }
        let docx = try filePromise(wordDocument(), named: "cours.docx", typeIdentifier: docxIdentifier, in: folder)
        let odt = try filePromise(wordDocument(), named: "texte.odt", typeIdentifier: "org.oasis-open.opendocument.text", in: folder)
        let items = await PasteImport.items(from: [docx, odt])
        defer { items.forEach(discard) }
        #expect(items.count == 2)
        guard case .attachment = items[0] else { Issue.record("pièce jointe attendue, reçu \(items[0])"); return }
        #expect(items[1] == .refused(.unsupportedType))
        // Le collage garde les fichiers ET les refus (le texte appartient au champ de saisie).
        let kept = DropPlan.attachableOnly(items)
        #expect(kept.count == 2)
        #expect(DropPlan(items: kept).refusalMessage == unsupportedMessage)
    }
}

// MARK: - Classement du presse-papiers

@Suite("Word — presse-papiers")
struct WordPasteboardTests {
    @Test("Nature d'un élément d'après ses types", arguments: [
        (["public.file-url"], PasteboardClassifier.ProviderKind.file),
        ([docxIdentifier], .file),
        ([docxIdentifier, "public.data"], .file),
        (["com.adobe.pdf"], .file),
        (["com.microsoft.word.doc"], .unsupportedFile),
        (["org.oasis-open.opendocument.text"], .unsupportedFile),
        (["public.zip-archive"], .unsupportedFile),
        (["org.openxmlformats.wordprocessingml.template"], .unsupportedFile),
        (["public.utf8-plain-text"], .other),
        (["public.html", "public.utf8-plain-text"], .other),
        (["public.url", "public.utf8-plain-text"], .other),
        (["public.png"], .other),
        (["com.apple.property-list"], .other),
        (["n'importe quoi", ""], .other),
        ([], .other),
    ])
    func kindOfTypes(identifiers: [String], expected: PasteboardClassifier.ProviderKind) {
        #expect(PasteboardClassifier.kind(ofTypeIdentifiers: identifiers) == expected, "\(identifiers)")
    }

    @Test("Seul un fichier non pris en charge : refus expliqué, pas « presse-papiers vide »")
    func unsupportedAlone() {
        #expect(PasteboardClassifier.decision(for: .init(hasUnsupportedFileItem: true)) == .unsupportedFile)
    }

    @Test("Le texte, une image ou un fichier lisible l'emportent sur un fichier non pris en charge")
    func otherThingsWin() {
        #expect(PasteboardClassifier.decision(for: .init(text: "Bonjour", hasUnsupportedFileItem: true)) == .text)
        #expect(PasteboardClassifier.decision(for: .init(hasImage: true, hasUnsupportedFileItem: true)) == .image)
        #expect(PasteboardClassifier.decision(for: .init(hasFileItem: true, hasUnsupportedFileItem: true)) == .files)
        #expect(PasteboardClassifier.decision(for: .init(text: "  \n", hasUnsupportedFileItem: true)) == .unsupportedFile)
        #expect(PasteboardClassifier.decision(for: .init()) == .nothing)
    }
}

// MARK: - Partage (extension « Rechercher avec Triva »)

@MainActor
@Suite("Word — partage")
struct WordShareTests {
    private func read(_ provider: NSItemProvider, in root: URL) async throws -> ShareContent {
        let item = NSExtensionItem()
        item.attachments = [provider]
        return try await ShareItemReader.read([item], stagingDirectory: root.appendingPathComponent("staging", isDirectory: true))
    }

    @Test("Un .docx partagé est copié, reconnu par son répertoire central, nommé en .docx")
    func docxShared() async throws {
        let root = try TestFiles.makeFolder("share-docx")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try filePromise(wordDocument(), named: "Cours d'histoire.docx", typeIdentifier: docxIdentifier, in: root)
        let content = try await read(provider, in: root)
        guard case .file(let file) = content else { Issue.record("fichier attendu, reçu \(content)"); return }
        #expect(file.type == .docx)
        #expect(file.displayName == "Cours d'histoire.docx", "nom reçu : \(file.displayName)")
        #expect(file.byteCount == wordDocument().count)
        #expect(content.suggestedQuestion == nil)
    }

    @Test("Refusés (« Triva ne lit pas ce type de fichier. ») : ancien .doc, .odt, .pages, archive, et un classeur nommé .docx",
          arguments: [
              ("ancien.doc", "com.microsoft.word.doc", Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 100)),
              ("texte.odt", "org.oasis-open.opendocument.text", ZipFixture.build([.init(name: "mimetype", data: Data("x".utf8), method: 0)])),
              ("texte.pages", "com.apple.iwork.pages.pages", ZipFixture.build([.init(name: "Index/Document.iwa", data: Data("x".utf8))])),
              ("archive.zip", "public.zip-archive", ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])),
              ("classeur.docx", docxIdentifier, ZipFixture.build([.init(name: "xl/workbook.xml", data: Data("<a/>".utf8))])),
              ("faux.docx", docxIdentifier, Data("pas une archive".utf8)),
          ])
    func refused(name: String, typeIdentifier: String, data: Data) async throws {
        let root = try TestFiles.makeFolder("share-refused")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try filePromise(data, named: name, typeIdentifier: typeIdentifier, in: root)
        await #expect(throws: ShareReadError.unsupportedFile) { _ = try await read(provider, in: root) }
        #expect(ShareMessages.message(for: .unsupportedFile) == unsupportedMessage)
        let staging = root.appendingPathComponent("staging")
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: staging.path)) ?? []
        #expect(leftovers.allSatisfy { !$0.contains(".") }, "aucun fichier ne reste : \(leftovers)")
    }

    @Test("La boîte de partage garde un .docx, le rend à l'app avec son nom, et refuse un classeur")
    func inboxRoundTrip() async throws {
        let root = try TestFiles.makeFolder("share-inbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedInbox(directory: root.appendingPathComponent("inbox", isDirectory: true))
        let docx = try TestFiles.write(wordDocument(), named: "source.bin", in: root)
        let entry = try inbox.add(text: nil, fileAt: docx, displayName: "Cours.docx")
        #expect(entry.file?.type == .docx)
        #expect(entry.file?.displayName == "Cours.docx")
        #expect(inbox.validEntries().first?.file?.type == .docx)

        let sheet = try TestFiles.write(ZipFixture.build([.init(name: "xl/workbook.xml", data: Data("<a/>".utf8))]), named: "classeur.bin", in: root)
        #expect(throws: SharedInbox.Failure.unsupportedFile) { try inbox.add(text: nil, fileAt: sheet, displayName: "Classeur.docx") }

        let handoff = try #require(await SharedInboxHandoff.takeAll(from: inbox, depositRoot: root.appendingPathComponent("deposits")).first)
        let deposit = try #require(handoff.depositURL)
        #expect(deposit.lastPathComponent == "Cours.docx")
        #expect(AttachmentKind(fileName: deposit.lastPathComponent) == .docx)
        let extracted = try AttachmentTextExtractor().extract(data: try Data(contentsOf: deposit), fileName: deposit.lastPathComponent)
        #expect(extracted.kind == .docx)
    }
}

// MARK: - Oracle (Mac seulement)

#if canImport(AppKit)
@Suite("Word — comparaison avec le lecteur de macOS (oracle)")
struct WordOracleTests {
    /// `NSAttributedString` lit le .docx sur macOS SEULEMENT : il ne sert ici que de référence pour vérifier que le
    /// lecteur d'Apple Triva (identique sur toutes les plateformes) trouve les mêmes mots, jamais en production.
    @Test("Un document écrit par macOS lui-même est relu avec les mêmes mots")
    func sameWordsAsAppKit() throws {
        let source = NSMutableAttributedString(string: "Titre du cours\nPremière partie : la naissance de l'Europe.\nDeuxième partie : les royaumes francs.\n")
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: 14))
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])

        let ours = try DocxTextReader().read(data: data, characterLimit: 100_000).text
        let reference = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(words(ours) == words(reference))
        #expect(ours.contains("Première partie : la naissance de l'Europe."))
    }
}
#endif
