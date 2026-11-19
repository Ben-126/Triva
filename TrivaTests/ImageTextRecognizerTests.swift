//
//  ImageTextRecognizerTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M6) : lecture locale du texte des images (Vision). Une partie des tests utilise le VRAI Vision sur une
//  image fabriquée avec CoreText (texte connu) ; le reste injecte un faux lecteur pour les cas limites.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Triva

// MARK: - Images fabriquées

/// PNG blanc portant `lines` en noir (une ligne par ligne), dessiné avec CoreText : aucun fichier de test.
/// `lines` vide : image blanche, sans texte.
private func makeTextPNG(lines: [String], fontSize: CGFloat = 54) -> Data {
    let width = 1_400
    let lineHeight = Int(fontSize * 1.6)
    let height = max(200, lineHeight * lines.count + 120)
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    for (index, text) in lines.enumerated() {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!)
        context.textPosition = CGPoint(x: 60, y: CGFloat(height - 90 - index * lineHeight))
        CTLineDraw(line, context)
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Faux lecteur : rend toujours `result`, ou lève `error`.
private struct FakeRecognizer: ImageTextRecognizing {
    var result = ""
    var error: AttachmentExtractionError?

    func recognizeText(inImageData data: Data) async throws -> String {
        if let error { throw error }
        return result
    }
}

private func withTemporaryFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OCRTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(folder)
}

// MARK: - Assemblage (pur)

@Suite("Lecture d'image — assemblage des lignes")
struct ImageTextAssemblyTests {
    @Test("Lignes rognées, vides retirées, jointes par un saut de ligne")
    func assemblesLines() {
        let text = VisionImageTextRecognizer.assemble(lines: ["  Bonjour ", "", "   ", "le monde\n"])
        #expect(text == "Bonjour\nle monde")
    }

    @Test("Aucune ligne : chaîne vide")
    func noLines() {
        #expect(VisionImageTextRecognizer.assemble(lines: []).isEmpty)
        #expect(VisionImageTextRecognizer.assemble(lines: [" ", ""]).isEmpty)
    }
}

// MARK: - Types

@Suite("Lecture d'image — types acceptés")
struct ImageKindTests {
    @Test("Formats d'image courants reconnus par l'extension, casse indifférente", arguments: [
        "capture.png", "PHOTO.JPG", "photo.jpeg", "iphone.heic", "scan.tiff", "anim.gif", "vieux.bmp", "web.webp", "Capture d'écran.PNG",
    ])
    func imagesAreImages(fileName: String) {
        #expect(AttachmentKind(fileName: fileName) == .image)
    }

    @Test("Dessin vectoriel, format non lu ou fichier sans extension : pas une image lisible", arguments: [
        "logo.svg", "image", "photo.", "fichier.psd",
    ])
    func othersAreNotImages(fileName: String) {
        #expect(AttachmentKind(fileName: fileName) != .image)
    }

    @Test("Le sélecteur propose les images, et seulement elles pour ce type")
    func pickerOffersImages() {
        for type in AttachmentKind.imageTypes {
            #expect(FileAttachmentRules.accepts(type), "\(type.identifier)")
        }
        #expect(FileAttachmentRules.contentTypes(for: .image) == AttachmentKind.imageTypes)
        #expect(!FileAttachmentRules.accepts(.svg))
        #expect(FileAttachmentPresentation.symbolName(for: .image) == "photo")
    }

    @Test("Un PDF, un JSON ou un texte ne deviennent jamais des images")
    func documentsAreNotImages() {
        #expect(AttachmentKind(fileName: "a.pdf") == .pdf)
        #expect(AttachmentKind(fileName: "a.json") == .json)
        #expect(AttachmentKind(fileName: "a.txt") == .plainText)
    }
}

// MARK: - Extracteur avec un faux lecteur

@Suite("Lecture d'image — extracteur")
struct ImageExtractorTests {
    private let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00])

    @Test("Le texte reconnu devient une section unique, sans page, type image")
    func successBuildsOneSection() async throws {
        let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: "  Ligne un\r\nLigne deux  "))
        let result = try await extractor.extractImage(data: bytes, fileName: "capture.png")
        #expect(result.kind == .image)
        #expect(result.fileName == "capture.png")
        #expect(result.sections == [ExtractedTextSection(pageNumber: nil, text: "Ligne un\nLigne deux")])
        #expect(result.pageCount == nil)
        #expect(!result.isTruncated)
        #expect(!result.isCopyRestricted)
        #expect(result.textEncoding == nil)
    }

    @Test("Aucun texte reconnu : erreur dédiée, pas une pièce jointe vide")
    func noTextIsAnError() async {
        let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: " \n "))
        await #expect(throws: AttachmentExtractionError.noTextInImage) {
            try await extractor.extractImage(data: bytes, fileName: "paysage.jpg")
        }
    }

    @Test("Image illisible : l'erreur du lecteur est relayée")
    func invalidImageIsRelayed() async {
        let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(error: .invalidImage))
        await #expect(throws: AttachmentExtractionError.invalidImage) {
            try await extractor.extractImage(data: bytes, fileName: "casse.png")
        }
    }

    @Test("Texte tronqué à la limite de caractères, signalé")
    func longTextIsTruncated() async throws {
        let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: "un deux trois quatre cinq six sept"))
        let result = try await extractor.extractImage(data: bytes, fileName: "long.png", characterLimit: 14)
        #expect(result.isTruncated)
        #expect(result.sections.first?.text == "un deux trois")
    }

    @Test("Fichier vide ou trop gros : refusé AVANT toute lecture")
    func emptyAndOversizedAreRefused() async {
        let extractor = AttachmentTextExtractor(maxImageByteCount: 4, imageRecognizer: FakeRecognizer(result: "jamais lu"))
        await #expect(throws: AttachmentExtractionError.emptyFile) {
            try await extractor.extractImage(data: Data(), fileName: "vide.png")
        }
        await #expect(throws: AttachmentExtractionError.imageTooLarge(byteCount: 5, maximumByteCount: 4)) {
            try await extractor.extractImage(data: bytes, fileName: "gros.png")
        }
    }

    @Test("Dimensions lues dans l'en-tête : largeur × hauteur, nil si ce n'est pas une image")
    func pixelCountComesFromTheHeader() {
        #expect(AttachmentTextExtractor.pixelCount(ofImageData: makeTextPNG(lines: [])) == 1_400 * 200)
        #expect(AttachmentTextExtractor.pixelCount(ofImageData: bytes) == nil)
        #expect(AttachmentTextExtractor.defaultMaxImagePixelCount == 100_000_000)
    }

    @Test("Image aux dimensions démesurées : refusée AVANT toute lecture, même si elle pèse peu")
    func oversizedDimensionsAreRefused() async throws {
        let png = makeTextPNG(lines: [])
        let strict = AttachmentTextExtractor(maxImagePixelCount: 10_000, imageRecognizer: FakeRecognizer(result: "jamais lu"))
        await #expect(throws: AttachmentExtractionError.imageDimensionsTooLarge) {
            try await strict.extractImage(data: png, fileName: "bombe.png")
        }
        // Même image, borne par défaut : acceptée.
        let normal = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: "Bonjour"))
        let result = try await normal.extractImage(data: png, fileName: "capture.png")
        #expect(result.sections.first?.text == "Bonjour")
    }

    @Test("Depuis un fichier : lu sous coordination, nom d'origine conservé")
    func readsFromFile() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("tableau blanc.png")
            try bytes.write(to: url)
            let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: "Réunion lundi"))
            let result = try await extractor.extract(from: url)
            #expect(result.kind == .image)
            #expect(result.fileName == "tableau blanc.png")
            #expect(result.sections.first?.text == "Réunion lundi")
        }
    }

    @Test("Depuis un fichier trop gros : refusé sans charger les octets")
    func oversizedFileIsRefused() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("gros.png")
            try bytes.write(to: url)
            let extractor = AttachmentTextExtractor(maxImageByteCount: 2, imageRecognizer: FakeRecognizer(result: "jamais lu"))
            await #expect(throws: AttachmentExtractionError.imageTooLarge(byteCount: 5, maximumByteCount: 2)) {
                try await extractor.extract(from: url)
            }
        }
    }

    @Test("Fichier absent : illisible, sans détail système")
    func missingFileIsUnreadable() async {
        let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: "x"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).png")
        await #expect(throws: AttachmentExtractionError.fileUnreadable) {
            try await extractor.extract(from: missing)
        }
    }

    @Test("La lecture synchrone d'octets refuse une image (la reconnaissance est asynchrone)")
    func syncExtractionRefusesImages() {
        #expect(throws: AttachmentExtractionError.unsupportedFileType(fileExtension: "png")) {
            try AttachmentTextExtractor().extract(data: Data([1, 2, 3]), fileName: "a.png")
        }
    }

    @Test("Jusqu'au magasin : une image devient une pièce jointe interrogeable")
    @MainActor
    func imageBecomesIndexedAttachment() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("menu.jpg")
            try bytes.write(to: url)
            let extractor = AttachmentTextExtractor(imageRecognizer: FakeRecognizer(result: "Soupe du jour : potiron"))
            let store = AttachmentStore(preparer: AttachmentPreparer(extractor: extractor))
            let attachment = try await store.attach(fileAt: url)
            #expect(attachment.kind == .image)
            #expect(attachment.chunks.first?.text.contains("potiron") == true)
            #expect(attachment.characterCount == "Soupe du jour : potiron".count)
        }
    }
}

// MARK: - Vrai Vision

@Suite("Lecture d'image — Vision réel")
struct VisionRecognitionTests {
    @Test("Un texte imprimé est lu en local, avec ses lignes dans l'ordre")
    func readsPrintedText() async throws {
        let png = makeTextPNG(lines: ["Bonjour Triva", "Rendez-vous en 2026"])
        let text = try await VisionImageTextRecognizer().recognizeText(inImageData: png)
        let lowered = text.lowercased()
        #expect(lowered.contains("bonjour"), "lu : \(text)")
        #expect(lowered.contains("triva"), "lu : \(text)")
        #expect(text.contains("2026"), "lu : \(text)")
        let bonjour = try #require(lowered.range(of: "bonjour"))
        let rendezVous = try #require(lowered.range(of: "rendez"))
        #expect(bonjour.lowerBound < rendezVous.lowerBound)
    }

    @Test("Les accents français sont lus")
    func readsFrenchAccents() async throws {
        let png = makeTextPNG(lines: ["L'élève préfère l'été"])
        let text = try await VisionImageTextRecognizer().recognizeText(inImageData: png)
        #expect(text.lowercased().contains("été") || text.lowercased().contains("préf"), "lu : \(text)")
    }

    @Test("Image blanche : aucun texte, donc erreur dédiée à la jointure")
    func blankImageHasNoText() async throws {
        let png = makeTextPNG(lines: [])
        let text = try await VisionImageTextRecognizer().recognizeText(inImageData: png)
        #expect(text.isEmpty, "lu : \(text)")
        await #expect(throws: AttachmentExtractionError.noTextInImage) {
            try await AttachmentTextExtractor().extractImage(data: png, fileName: "blanc.png")
        }
    }

    @Test("Des octets qui ne sont pas une image : image illisible")
    func garbageIsInvalid() async {
        await #expect(throws: AttachmentExtractionError.invalidImage) {
            _ = try await VisionImageTextRecognizer().recognizeText(inImageData: Data("ceci n'est pas une image".utf8))
        }
    }
}

// MARK: - Dépôt d'une image sur la fenêtre

private func waitFor(timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private struct OCRKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
@Suite("Lecture d'image — dépôt et sélecteur")
struct ImageDropTests {
    private func makeCoordinator() throws -> TrivaRootCoordinator {
        let userDefaults = try #require(TestDefaults.suite(named: "test.ocr.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
            keyStore: OCRKeyStore()
        )
        return TrivaRootCoordinator(engine: .appleIntelligence, stores: stores, windowRegistry: WindowConversationRegistry())
    }

    @Test("Une image déposée est lue en local et jointe, avec Coup d'œil sur sa copie")
    func droppedImageIsReadAndAttached() async throws {
        try await withTemporaryFolder { folder in
            let origin = folder.appendingPathComponent("capture.png")
            try makeTextPNG(lines: ["Bonjour Triva"]).write(to: origin)
            let deposit = try AttachmentFileVault.stageDeposit(of: origin)
            let coordinator = try makeCoordinator()

            let plan = try #require(coordinator.receiveDrop([.image(deposit)]))
            #expect(plan.imageURLs == [deposit])
            let controller = try #require(coordinator.session.chatViewModel?.attachmentController)
            #expect(await waitFor { controller.attachments.count == 1 || !controller.notices.isEmpty })
            let attachment = try #require(controller.attachments.first, "refus : \(controller.notices.map(\.message))")
            #expect(attachment.kind == .image)
            #expect(attachment.fileName == "capture.png")
            #expect(attachment.chunks.first?.text.lowercased().contains("triva") == true)
            #expect(controller.previewURL(for: attachment.id) != nil)
            #expect(!FileManager.default.fileExists(atPath: deposit.path))
            controller.removeAll()
        }
    }

    @Test("Une image sans texte est expliquée sous les capsules, rien n'est joint")
    func blankImageIsExplained() async throws {
        try await withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("vide.png")
            try makeTextPNG(lines: []).write(to: url)
            let controller = FileAttachmentController(
                store: AttachmentStore(),
                vault: AttachmentFileVault(rootDirectory: folder.appendingPathComponent("coffre"))
            )
            controller.enqueue([url])
            #expect(await waitFor { !controller.notices.isEmpty })
            #expect(controller.attachments.isEmpty)
            #expect(controller.notices.last?.message == AttachmentExtractionError.noTextInImage.userFacingMessage)
            #expect(controller.pendingAttachments.isEmpty)
            controller.removeAll()
        }
    }
}
