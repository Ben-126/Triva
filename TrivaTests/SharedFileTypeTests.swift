//
//  SharedFileTypeTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : reconnaissance d'un PDF ou d'une image par ses premiers octets, et nom assaini.
//  Un fichier venu d'une autre app est une entrée externe : on ne se fie ni à son nom ni à son extension.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Triva

@Suite("Partage — type de fichier par les premiers octets")
struct SharedFileTypeTests {
    private static let knownSamples: [(Data, SharedFileType)] = {
        var samples: [(Data, SharedFileType)] = []
        samples.append((SampleBytes.pdf(), .pdf))
        samples.append((SampleBytes.png(), .png))
        samples.append((SampleBytes.jpeg(), .jpeg))
        samples.append((SampleBytes.gif(), .gif))
        samples.append((SampleBytes.bmp(), .bmp))
        samples.append((SampleBytes.tiffLittle(), .tiff))
        samples.append((SampleBytes.tiffBig(), .tiff))
        samples.append((SampleBytes.webp(), .webp))
        samples.append((SampleBytes.heic(brand: "heic"), .heic))
        samples.append((SampleBytes.heic(brand: "heix"), .heic))
        samples.append((SampleBytes.heic(brand: "mif1"), .heif))
        return samples
    }()

    @Test("Chaque format accepté est reconnu à son en-tête", arguments: knownSamples)
    func detectsKnownFormats(sample: Data, expected: SharedFileType) {
        #expect(SharedFileType.detect(header: sample) == expected)
    }

    @Test("Un PDF peut avoir quelques octets avant son en-tête (jusqu'à 1 024), pas davantage")
    func pdfHeaderWindow() {
        let early = Data(repeating: 0x0A, count: 200) + SampleBytes.pdf()
        let late = Data(repeating: 0x0A, count: 2_000) + SampleBytes.pdf()
        #expect(SharedFileType.detect(header: early) == .pdf)
        #expect(SharedFileType.detect(header: late) == nil)
    }

    private static let refusedSamples: [Data] = {
        var samples: [Data] = []
        samples.append(SampleBytes.executable())
        samples.append(Data())
        samples.append(SampleBytes.heic(brand: "avif"))
        samples.append(Data("Bonjour tout le monde".utf8))
        samples.append(Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 32))
        samples.append(Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8))
        return samples
    }()

    @Test("Exécutable, vide, AVIF, texte, archive ZIP, WAV : refusés", arguments: refusedSamples)
    func refusesOthers(sample: Data) {
        #expect(SharedFileType.detect(header: sample) == nil)
    }

    @Test("Lecture sur disque : seule la tête du fichier est lue, un fichier creux de 300 Mo ne coûte rien")
    func detectsFromFileWithoutLoadingIt() throws {
        let folder = try TestFiles.makeFolder("type")
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = try TestFiles.writeSparse(header: SampleBytes.pdf(), size: 300 * 1_024 * 1_024, named: "gros.pdf", in: folder)
        #expect(SharedFileType.detect(fileAt: big) == .pdf)
        #expect(SharedFileType.detect(fileAt: folder.appendingPathComponent("absent.pdf")) == nil)
    }

    @Test("Plafonds : 200 Mo pour un PDF ou un .docx, 50 Mo pour une image ; un .docx n'est jamais pris pour une image")
    func limits() {
        #expect(SharedFileType.pdf.maxByteCount == 200 * 1_024 * 1_024)
        #expect(SharedFileType.docx.maxByteCount == 200 * 1_024 * 1_024)
        for type in SharedFileType.allCases where type != .pdf && type != .docx {
            #expect(type.isImage)
            #expect(type.maxByteCount == 50 * 1_024 * 1_024)
        }
        #expect(!SharedFileType.pdf.isImage)
        #expect(!SharedFileType.docx.isImage)
        #expect(SharedFileType.docx.kindLabel == "Word" && SharedFileType.pdf.kindLabel == "PDF" && SharedFileType.png.kindLabel == "Image")
    }

    @Test("La liste fermée du partage est exactement celle de l'app : PDF, Word + formats d'image que Vision lit")
    func matchesTheAppAttachmentKinds() {
        for type in SharedFileType.allCases {
            let kind = AttachmentKind(fileName: "x.\(type.fileExtension)")
            let expected: AttachmentKind = type.isImage ? .image : (type == .docx ? .docx : .pdf)
            #expect(kind == expected, "extension \(type.fileExtension)")
        }
        let imageTypesCovered = SharedFileType.allCases.filter(\.isImage).compactMap { UTType(filenameExtension: $0.fileExtension) }
        for appType in AttachmentKind.imageTypes {
            #expect(imageTypesCovered.contains { $0.conforms(to: appType) }, "format \(appType.identifier) absent du partage")
        }
        #expect(imageTypesCovered.count == AttachmentKind.imageTypes.count)
    }
}

@Suite("Partage — reconnaissance d'un .docx sur disque")
struct SharedDocxDetectionTests {
    private func detect(_ data: Data, named name: String = "fichier.bin") throws -> SharedFileType? {
        let folder = try TestFiles.makeFolder("docx-type")
        defer { try? FileManager.default.removeItem(at: folder) }
        return SharedFileType.detect(fileAt: try TestFiles.write(data, named: name, in: folder))
    }

    @Test("Un vrai .docx est reconnu à son répertoire central, quel que soit le nom du fichier")
    func recognizesDocx() throws {
        #expect(try detect(DocxFixture.make(paragraphs: ["Bonjour"])) == .docx)
        #expect(try detect(DocxFixture.make(paragraphs: ["Bonjour"]), named: "document.pdf") == .docx)
    }

    @Test("Classeur, présentation, ODT, ZIP quelconque, ZIP à l'en-tête seul, ZIP vide : pas un .docx")
    func refusesOtherZips() throws {
        let xlsx = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "xl/workbook.xml", data: Data("<a/>".utf8)),
        ])
        let odt = ZipFixture.build([.init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.text".utf8), method: 0)])
        #expect(try detect(xlsx, named: "x.docx") == nil)
        #expect(try detect(odt, named: "x.docx") == nil)
        #expect(try detect(ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])) == nil)
        #expect(try detect(Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 200)) == nil)
        #expect(try detect(ZipFixture.build([])) == nil)
    }

    @Test("Un ZIP aux noms piégés ou tronqué n'est pas un .docx")
    func refusesTrappedAndTruncated() throws {
        let trapped = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "word/document.xml", data: Data("<a/>".utf8)),
            .init(name: "../evil", data: Data("x".utf8)),
        ])
        #expect(try detect(trapped) == nil)
        let full = DocxFixture.make(paragraphs: [String(repeating: "texte ", count: 2_000)])
        #expect(try detect(full.prefix(full.count - 30)) == nil)
    }

    @Test("Les octets de tête seuls ne suffisent pas : un en-tête ZIP n'est jamais un .docx")
    func headerAloneIsNotEnough() {
        #expect(SharedFileType.detect(header: DocxFixture.make(paragraphs: ["x"])) == nil)
    }
}

@Suite("Partage — nom de fichier assaini")
struct SharedFileNameTests {
    @Test("Nom normal : gardé, extension du type vérifié")
    func normalName() {
        #expect(SharedFileName.sanitized("Rapport 2026.pdf", type: .pdf) == "Rapport 2026.pdf")
        #expect(SharedFileName.sanitized("IMG_0042.HEIC", type: .heic) == "IMG_0042.heic")
    }

    @Test("Un .docx garde son extension et son nom de repli est « Document »")
    func docxName() {
        #expect(SharedFileName.sanitized("Cours d'histoire.docx", type: .docx) == "Cours d'histoire.docx")
        #expect(SharedFileName.sanitized(nil, type: .docx) == "Document.docx")
        #expect(SharedFileName.sanitized("cours.pdf", type: .docx) == "cours.docx")
    }

    @Test("L'extension vient du type RÉEL, jamais du nom : un PNG nommé .pdf devient .png")
    func extensionFollowsRealType() {
        #expect(SharedFileName.sanitized("facture.pdf", type: .png) == "facture.png")
        #expect(SharedFileName.sanitized("photo.jpg", type: .pdf) == "photo.pdf")
        #expect(SharedFileName.sanitized("sans-extension", type: .jpeg) == "sans-extension.jpg")
    }

    @Test("Nom piégé : aucun chemin, aucun caractère de contrôle ou de sens d'écriture, jamais vide", arguments: [
        "../../etc/passwd.pdf",
        "..\\..\\Windows\\x.pdf",
        "/absolu/chemin.pdf",
        "a/b/c/d.pdf",
        "\u{202E}fdp.exe",
        "nom\u{0}nul.pdf",
        "tab\t\nretour.pdf",
        "...",
        "..pdf",
        ".pdf",
        "   ",
        "",
        "rapport:final*?\"<>|.pdf",
        "\u{E0041}\u{E0042}tag.pdf",
        String(repeating: "x", count: 5_000) + ".pdf",
    ])
    func trappedNames(raw: String) {
        let clean = SharedFileName.sanitized(raw, type: .pdf)
        #expect(clean.hasSuffix(".pdf"))
        let stem = String(clean.dropLast(4))
        #expect(!stem.isEmpty)
        #expect(stem.count <= SharedFileName.maxStemLength)
        for forbidden in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0", "\n", "\t"] {
            #expect(!clean.contains(forbidden), "contient \(forbidden.debugDescription)")
        }
        #expect(!clean.hasPrefix("."))
        #expect(clean.unicodeScalars.allSatisfy { $0.properties.generalCategory != .format && $0.properties.generalCategory != .control })
    }

    @Test("Nom absent ou réduit à rien : « Document » pour un PDF, « Image » pour une image")
    func fallbackNames() {
        #expect(SharedFileName.sanitized(nil, type: .pdf) == "Document.pdf")
        #expect(SharedFileName.sanitized("///", type: .pdf) == "Document.pdf")
        #expect(SharedFileName.sanitized(nil, type: .jpeg) == "Image.jpg")
        #expect(SharedFileName.sanitized("..", type: .png) == "Image.png")
    }

    @Test("Les accents et les emoji d'un nom honnête sont gardés")
    func keepsHonestUnicode() {
        #expect(SharedFileName.sanitized("Résumé été 🌊.pdf", type: .pdf) == "Résumé été 🌊.pdf")
    }
}
