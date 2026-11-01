//
//  AttachmentTextExtractorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 29/09/2026.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import Triva

// MARK: - Fabriques

/// PDF construits EN MÉMOIRE plutôt qu'un binaire embarqué dans le dépôt :
/// chaque test montre exactement le contenu qu'il vérifie. CoreGraphics +
/// CoreText existent à l'identique sur iOS et macOS — ni UIKit
/// (`UIGraphicsPDFRenderer`) ni AppKit, pour que la même fabrique serve sur le
/// simulateur comme sur Mac. Le texte dessiné par CoreText est embarqué avec
/// sa table ToUnicode : PDFKit le relit comme un vrai PDF texte (vérifié sur
/// macOS 27, accents compris).
private enum TestPDF {
    static func make(pages: [String], auxiliaryInfo: [CFString: Any] = [:]) throws -> Data {
        try render(auxiliaryInfo: auxiliaryInfo) { context in
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            for page in pages {
                context.beginPDFPage(nil)
                var baseline: CGFloat = 740
                for line in page.split(separator: "\n", omittingEmptySubsequences: false) {
                    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
                    let attributed = NSAttributedString(string: String(line), attributes: attributes)
                    context.textPosition = CGPoint(x: 72, y: baseline)
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                    baseline -= 16
                }
                context.endPDFPage()
            }
        }
    }

    /// Pages faites d'un simple aplat : l'équivalent d'un scan, sans aucune
    /// couche texte (`PDFPage.string` y renvoie `nil`, vérifié).
    static func makeImageOnly(pageCount: Int) throws -> Data {
        try render(auxiliaryInfo: [:]) { context in
            for _ in 0..<pageCount {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 0.4, alpha: 1))
                context.fill(CGRect(x: 60, y: 60, width: 400, height: 500))
                context.endPDFPage()
            }
        }
    }

    private static func render(auxiliaryInfo: [CFString: Any], draw: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, auxiliaryInfo as CFDictionary))
        draw(context)
        context.closePDF()
        return data as Data
    }
}

/// Fichier écrit dans un dossier temporaire UNIQUE (un par appel), pour que
/// deux tests parallèles ne se marchent jamais dessus.
private func writeTemporaryFile(named fileName: String, contents: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AttachmentExtractorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(fileName)
    try contents.write(to: url)
    return url
}

private func removeTemporaryDirectory(of url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

// MARK: - PDF

@Suite("Extraction — PDF")
struct AttachmentExtractorPDFTests {
    private let extractor = AttachmentTextExtractor()

    @Test("Une section par page non vide, numérotée à partir de 1 ; la page blanche est sautée")
    func sectionsFollowPages() throws {
        let data = try TestPDF.make(pages: ["Première page du cours.", "", "Troisième page\nsur deux lignes"])

        let result = try extractor.extract(data: data, fileName: "cours.pdf")

        #expect(result.kind == .pdf)
        #expect(result.pageCount == 3)
        #expect(result.sections.map(\.pageNumber) == [1, 3])
        #expect(result.sections.map(\.text) == ["Première page du cours.", "Troisième page\nsur deux lignes"])
        #expect(!result.isTruncated)
        #expect(!result.isCopyRestricted)
        #expect(result.textEncoding == nil)
    }

    @Test("PDF protégé par un mot de passe d'ouverture : refus explicite")
    func passwordProtected() throws {
        let data = try TestPDF.make(
            pages: ["Contenu secret"],
            auxiliaryInfo: [kCGPDFContextUserPassword: "motdepasse", kCGPDFContextOwnerPassword: "proprietaire"]
        )

        #expect(throws: AttachmentExtractionError.passwordProtectedPDF) {
            try extractor.extract(data: data, fileName: "secret.pdf")
        }
    }

    @Test("Restriction de copie : texte lu normalement, drapeau levé pour le produit")
    func copyRestricted() throws {
        let data = try TestPDF.make(
            pages: ["Contenu restreint mais lisible"],
            auxiliaryInfo: [kCGPDFContextOwnerPassword: "proprietaire", kCGPDFContextAllowsCopying: false]
        )

        let result = try extractor.extract(data: data, fileName: "restreint.pdf")

        #expect(result.isCopyRestricted)
        #expect(result.sections.map(\.text) == ["Contenu restreint mais lisible"])
    }

    @Test("Octets corrompus, tronqués ou qui ne sont pas un PDF : invalidPDF")
    func invalidPDFData() throws {
        let valid = try TestPDF.make(pages: ["Texte"])
        let corruptedInputs = [
            Data("ceci n'est pas un pdf".utf8),
            Data("%PDF-1.7\n%%EOF".utf8),
            valid.prefix(valid.count / 2),
        ]

        for input in corruptedInputs {
            #expect(throws: AttachmentExtractionError.invalidPDF) {
                try extractor.extract(data: input, fileName: "casse.pdf")
            }
        }
    }

    @Test("PDF de zéro octet : emptyFile, pas invalidPDF")
    func emptyPDF() {
        #expect(throws: AttachmentExtractionError.emptyFile) {
            try extractor.extract(data: Data(), fileName: "vide.pdf")
        }
    }

    @Test("Scan sans couche texte : erreur dédiée avec le nombre de pages, jamais un document vide")
    func scannedPDF() throws {
        let data = try TestPDF.makeImageOnly(pageCount: 2)

        #expect(throws: AttachmentExtractionError.noExtractableText(pageCount: 2)) {
            try extractor.extract(data: data, fileName: "scan.pdf")
        }
    }

    @Test("Borne de pages : seules les premières sont lues, résultat marqué tronqué")
    func pageLimit() throws {
        let data = try TestPDF.make(pages: ["Page un.", "Page deux.", "Page trois.", "Page quatre."])

        let result = try AttachmentTextExtractor(maxPDFPageCount: 2).extract(data: data, fileName: "long.pdf")

        #expect(result.sections.map(\.pageNumber) == [1, 2])
        #expect(result.pageCount == 4)
        #expect(result.isTruncated)
    }

    @Test("Borne de caractères : la page qui déborde est coupée sur un blanc, jamais au milieu d'un mot")
    func characterLimitAcrossPages() throws {
        // « Un deux trois. » compte 14 caractères : il en reste 9 pour la
        // page 2, soit « Quatre ci » — on recule au blanc, « Quatre ».
        let data = try TestPDF.make(pages: ["Un deux trois.", "Quatre cinq six.", "Sept."])

        let result = try AttachmentTextExtractor(maxCharacterCount: 23).extract(data: data, fileName: "borne.pdf")

        #expect(result.sections.map(\.text) == ["Un deux trois.", "Quatre"])
        #expect(result.sections.map(\.pageNumber) == [1, 2])
        #expect(result.isTruncated)
    }

    @Test("Ligatures typographiques développées dans le texte d'un PDF")
    func ligaturesAreExpanded() {
        let normalized = AttachmentTextExtractor.normalizedPDFText("Le \u{FB01}chier \u{FB02}ottant, e\u{FB00}et")

        #expect(normalized == "Le fichier flottant, effet")
    }
}

// MARK: - Texte

@Suite("Extraction — texte et encodages")
struct AttachmentExtractorTextTests {
    private let extractor = AttachmentTextExtractor()

    @Test("UTF-8 sans marque : texte intact, sans pagination")
    func utf8() throws {
        let result = try extractor.extract(data: Data("Été à Noël : déjà ?".utf8), fileName: "notes.txt")

        #expect(result.kind == .plainText)
        #expect(result.textEncoding == .utf8)
        #expect(result.sections == [ExtractedTextSection(pageNumber: nil, text: "Été à Noël : déjà ?")])
        #expect(result.pageCount == nil)
        #expect(!result.isTruncated)
    }

    @Test("Marque UTF-8 retirée du texte")
    func utf8WithByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("Bonjour".utf8))

        let result = try extractor.extract(data: data, fileName: "bom.txt")

        #expect(result.sections.first?.text == "Bonjour")
        #expect(result.textEncoding == .utf8)
    }

    @Test("UTF-16 avec marque, petit et gros boutiste")
    func utf16() throws {
        let littleEndian = Data([0xFF, 0xFE]) + (try #require("Été, déjà".data(using: .utf16LittleEndian)))
        let bigEndian = Data([0xFE, 0xFF]) + (try #require("Été, déjà".data(using: .utf16BigEndian)))

        let little = try extractor.extract(data: littleEndian, fileName: "le.txt")
        let big = try extractor.extract(data: bigEndian, fileName: "be.txt")

        #expect(little.sections.first?.text == "Été, déjà")
        #expect(little.textEncoding == .utf16LittleEndian)
        #expect(big.sections.first?.text == "Été, déjà")
        #expect(big.textEncoding == .utf16BigEndian)
    }

    @Test("Long texte français en Windows-1252 : reconnu tel quel, accents, € et œ intacts")
    func longWindows1252Paragraph() throws {
        // Paragraphe long et réaliste : c'est le cas qu'un repli « UTF-8
        // tolérant » avec seuil laisserait passer en remplaçant chaque accent.
        let paragraph = String(
            repeating: "Cet été, à Noël, l'élève a reçu un cœur en chocolat pour 5 € ; déjà ça ! ",
            count: 30
        ).trimmingCharacters(in: .whitespaces)
        let data = try #require(paragraph.data(using: .windowsCP1252))

        let result = try extractor.extract(data: data, fileName: "ancien.txt")

        #expect(result.textEncoding == .windowsCP1252)
        #expect(result.sections.first?.text == paragraph)
    }

    @Test("Octets non définis en Windows-1252 : repli Latin-1, qui accepte tout octet")
    func latin1Fallback() throws {
        let result = try extractor.extract(data: Data([0x41, 0x81, 0x42, 0xE9]), fileName: "latin.txt")

        #expect(result.textEncoding == .isoLatin1)
        #expect(result.sections.first?.text == "A\u{81}Bé")
    }

    @Test("Marque UTF-8 suivie d'octets invalides : undecodableText, pas de charabia")
    func invalidBytesAfterByteOrderMark() {
        #expect(throws: AttachmentExtractionError.undecodableText) {
            try extractor.extract(data: Data([0xEF, 0xBB, 0xBF, 0xFF, 0xFE, 0x41]), fileName: "casse.txt")
        }
    }

    @Test("Fichier vide ou uniquement blanc : emptyFile")
    func emptyText() {
        #expect(throws: AttachmentExtractionError.emptyFile) {
            try extractor.extract(data: Data(), fileName: "vide.txt")
        }
        #expect(throws: AttachmentExtractionError.emptyFile) {
            try extractor.extract(data: Data("  \n\t \r\n ".utf8), fileName: "blanc.md")
        }
    }

    @Test("Image PNG renommée en .txt : binaryContent")
    func disguisedBinary() {
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]

        #expect(throws: AttachmentExtractionError.binaryContent) {
            try extractor.extract(data: Data(pngHeader), fileName: "photo.txt")
        }
    }

    @Test("Binaire sans octet nul mais truffé d'octets de contrôle : binaryContent")
    func controlHeavyBinary() {
        let bytes = (0..<200).map { UInt8($0 % 8 + 1) }

        #expect(throws: AttachmentExtractionError.binaryContent) {
            try extractor.extract(data: Data(bytes), fileName: "bruit.txt")
        }
    }

    @Test("Journal de terminal avec séquences de couleur : reste un texte")
    func terminalLogIsText() throws {
        let log = String(repeating: "\u{1B}[32mOK\u{1B}[0m tâche terminée\n", count: 10)

        let result = try extractor.extract(data: Data(log.utf8), fileName: "build.log")

        #expect(result.kind == .plainText)
        #expect(result.sections.first?.text.contains("tâche terminée") == true)
    }

    @Test("Fins de ligne Windows et ancien Mac unifiées en \\n")
    func lineEndingsAreNormalized() throws {
        let result = try extractor.extract(data: Data("Ligne 1\r\nLigne 2\rLigne 3".utf8), fileName: "fins.txt")

        #expect(result.sections.first?.text == "Ligne 1\nLigne 2\nLigne 3")
    }

    @Test("Troncature : la coupe juste avant un blanc garde le dernier mot entier")
    func truncationKeepsWholeLastWord() throws {
        let text = Data("Alpha beta gamma delta".utf8)

        let atBoundary = try AttachmentTextExtractor(maxCharacterCount: 10).extract(data: text, fileName: "a.txt")
        let insideWord = try AttachmentTextExtractor(maxCharacterCount: 10).extract(data: text, fileName: "a.txt", characterLimit: 7)
        let raisedLimit = try AttachmentTextExtractor(maxCharacterCount: 10).extract(data: text, fileName: "a.txt", characterLimit: 50)

        #expect(atBoundary.sections.first?.text == "Alpha beta")
        #expect(atBoundary.isTruncated)
        #expect(insideWord.sections.first?.text == "Alpha")
        // Une limite d'appelant plus haute que le plafond ne le relève jamais.
        #expect(raisedLimit.sections.first?.text == "Alpha beta")
    }

    @Test("Troncature : aucun graphème coupé (emoji composés, accents décomposés, drapeaux)")
    func truncationNeverSplitsGraphemes() throws {
        let original = String(repeating: "Café 👨‍👩‍👧‍👦 e\u{301}te\u{301} 🇫🇷🇨🇦 fin ", count: 4)

        for limit in [1, 3, 5, 6, 7, 9, 12] {
            let result = try AttachmentTextExtractor(maxCharacterCount: limit)
                .extract(data: Data(original.utf8), fileName: "unicode.txt")
            let text = try #require(result.sections.first?.text)

            #expect(text.count <= limit)
            #expect(Set(text).isSubset(of: Set(original)))
        }
    }

    @Test("Markdown, CSV, TSV, JSON et journaux lus comme du texte, type reconnu", arguments: zip(
        ["notes.md", "table.csv", "export.tsv", "data.json", "journal.log", "NOTES.TXT"],
        [AttachmentKind.markdown, .csv, .csv, .json, .plainText, .plainText]
    ))
    func textualKinds(fileName: String, kind: AttachmentKind) throws {
        let result = try extractor.extract(data: Data("nom;âge\nAlice;30".utf8), fileName: fileName)

        #expect(result.kind == kind)
        #expect(result.sections.first?.text == "nom;âge\nAlice;30")
    }

    @Test("Fichier texte au-delà de la borne d'octets : fileTooLarge")
    func textTooLarge() {
        #expect(throws: AttachmentExtractionError.fileTooLarge(byteCount: 11, maximumByteCount: 10)) {
            try AttachmentTextExtractor(maxTextFileByteCount: 10).extract(data: Data("onze octets".utf8), fileName: "gros.txt")
        }
    }
}

// MARK: - Types de fichiers

@Suite("Extraction — types de fichiers")
struct AttachmentExtractorTypeTests {
    @Test("Types refusés explicitement, avec leur extension", arguments: [
        "rapport.docx", "photo.png", "page.html", "lettre.rtf", "archive.zip", "données.xml", "sans_extension",
    ])
    func unsupportedTypes(fileName: String) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()

        #expect(AttachmentKind(fileName: fileName) == nil)
        #expect(throws: AttachmentExtractionError.unsupportedFileType(fileExtension: fileExtension)) {
            try AttachmentTextExtractor().extract(data: Data("contenu".utf8), fileName: fileName)
        }
    }

    @Test("Types acceptés, casse de l'extension indifférente", arguments: zip(
        ["cours.pdf", "Rapport.PDF", "notes.txt", "README.md", "guide.markdown", "table.csv", "table.tsv", "data.json", "script.swift"],
        [AttachmentKind.pdf, .pdf, .plainText, .markdown, .markdown, .csv, .csv, .json, .plainText]
    ))
    func supportedTypes(fileName: String, kind: AttachmentKind) {
        #expect(AttachmentKind(fileName: fileName) == kind)
    }
}

// MARK: - Fichiers sur disque

@Suite("Extraction — fichiers sur disque")
struct AttachmentExtractorFileTests {
    private let extractor = AttachmentTextExtractor()

    @Test("Fichier texte lu depuis son URL")
    func readsTextFile() async throws {
        let url = try writeTemporaryFile(named: "notes.txt", contents: Data("Bonjour depuis le disque.".utf8))
        defer { removeTemporaryDirectory(of: url) }

        let result = try await extractor.extract(from: url)

        #expect(result.fileName == "notes.txt")
        #expect(result.sections.first?.text == "Bonjour depuis le disque.")
    }

    @Test("PDF lu depuis son URL, pages conservées")
    func readsPDFFile() async throws {
        let url = try writeTemporaryFile(named: "cours.pdf", contents: try TestPDF.make(pages: ["Page un.", "Page deux."]))
        defer { removeTemporaryDirectory(of: url) }

        let result = try await extractor.extract(from: url)

        #expect(result.pageCount == 2)
        #expect(result.sections.map(\.pageNumber) == [1, 2])
    }

    @Test("Fichier introuvable : fileUnreadable")
    func missingFile() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).txt")

        await #expect(throws: AttachmentExtractionError.fileUnreadable) {
            try await extractor.extract(from: url)
        }
    }

    @Test("Type refusé AVANT tout accès disque : un .docx inexistant est refusé pour son type")
    func typeCheckedBeforeDiskAccess() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).docx")

        await #expect(throws: AttachmentExtractionError.unsupportedFileType(fileExtension: "docx")) {
            try await extractor.extract(from: url)
        }
    }

    @Test("Fichier de zéro octet sur disque : emptyFile")
    func emptyFileOnDisk() async throws {
        let url = try writeTemporaryFile(named: "vide.pdf", contents: Data())
        defer { removeTemporaryDirectory(of: url) }

        await #expect(throws: AttachmentExtractionError.emptyFile) {
            try await extractor.extract(from: url)
        }
    }

    @Test("Fichier texte trop gros sur disque : refusé sur sa taille, avant lecture")
    func tooLargeOnDisk() async throws {
        let url = try writeTemporaryFile(named: "gros.csv", contents: Data("0123456789".utf8))
        defer { removeTemporaryDirectory(of: url) }

        await #expect(throws: AttachmentExtractionError.fileTooLarge(byteCount: 10, maximumByteCount: 4)) {
            try await AttachmentTextExtractor(maxTextFileByteCount: 4).extract(from: url)
        }
    }

    @Test("PDF corrompu sur disque : invalidPDF")
    func corruptedPDFOnDisk() async throws {
        let url = try writeTemporaryFile(named: "casse.pdf", contents: Data("pas un pdf".utf8))
        defer { removeTemporaryDirectory(of: url) }

        await #expect(throws: AttachmentExtractionError.invalidPDF) {
            try await extractor.extract(from: url)
        }
    }
}

// MARK: - Préparation complète

@Suite("Préparation d'une pièce jointe (extraction + découpage)")
struct AttachmentPreparerTests {
    @Test("PDF : fragments paginés, métadonnées reportées")
    func preparesPDF() async throws {
        let url = try writeTemporaryFile(named: "cours.pdf", contents: try TestPDF.make(pages: ["Page un.", "Page deux."]))
        defer { removeTemporaryDirectory(of: url) }

        let attachment = try await AttachmentPreparer().prepareAttachment(fileAt: url, characterLimit: 1_000)

        #expect(attachment.fileName == "cours.pdf")
        #expect(attachment.kind == .pdf)
        #expect(attachment.pageCount == 2)
        #expect(attachment.chunks.map(\.text) == ["Page un.\n\nPage deux."])
        #expect(attachment.chunks.map(\.pageRange) == [1...2])
    }

    @Test("La limite de caractères de l'appelant borne l'extraction et se voit")
    func honorsCharacterLimit() async throws {
        let url = try writeTemporaryFile(named: "long.txt", contents: Data("Alpha beta gamma delta epsilon".utf8))
        defer { removeTemporaryDirectory(of: url) }

        let attachment = try await AttachmentPreparer().prepareAttachment(fileAt: url, characterLimit: 11)

        #expect(attachment.characterCount <= 11)
        #expect(attachment.isTruncated)
        #expect(attachment.chunks.map(\.text) == ["Alpha beta"])
    }
}

// MARK: - Messages

@Suite("Extraction — messages d'erreur")
struct AttachmentExtractorMessageTests {
    @Test("Chaque erreur a un message en français, sans reprendre de donnée du fichier")
    func everyErrorHasAMessage() {
        let errors: [AttachmentExtractionError] = [
            .unsupportedFileType(fileExtension: "docx"), .fileUnreadable,
            .fileTooLarge(byteCount: 20_971_520, maximumByteCount: 10_485_760), .emptyFile, .binaryContent,
            .undecodableText, .invalidPDF, .passwordProtectedPDF, .noExtractableText(pageCount: 3),
        ]

        for error in errors {
            #expect(!error.userFacingMessage.isEmpty)
            #expect(!error.userFacingMessage.contains("docx"))
        }
        #expect(AttachmentExtractionError.fileTooLarge(byteCount: 20_971_520, maximumByteCount: 10_485_760)
            .userFacingMessage.contains("10 Mo"))
        #expect(!AttachmentStoreError.characterBudgetExhausted.userFacingMessage.isEmpty)
    }
}
