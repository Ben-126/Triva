//
//  ZipArchiveIndexTests.swift
//  TrivaTests
//
//  Mission W : lecture du répertoire central d'une archive ZIP (partagée avec l'extension de partage, qui ne lit JAMAIS
//  le contenu des entrées). Tout ce qui est incohérent est refusé : taille mensongère, nom piégé, doublon, tronqué.
//

import Foundation
import Testing
@testable import Triva

@Suite("ZIP — répertoire central")
struct ZipArchiveIndexTests {
    private static func index(_ data: Data) throws -> ZipArchiveIndex {
        try ZipArchiveIndex(source: ZipDataSource(data))
    }

    private static func expectFailure(_ data: Data, _ expected: ZipArchiveError, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) { try index(data) }
    }

    @Test("Une archive valide est listée, avec méthode et tailles")
    func listsEntries() throws {
        let archive = ZipFixture.build([
            .init(name: "a.txt", data: Data("bonjour".utf8), method: 0),
            .init(name: "dossier/b.txt", data: Data(repeating: 0x41, count: 5_000), method: 8),
        ])
        let index = try Self.index(archive)
        #expect(index.entries.count == 2)
        let first = try #require(index.entry(named: "a.txt"))
        #expect(first.method == 0 && first.uncompressedSize == 7 && first.compressedSize == 7)
        let second = try #require(index.entry(named: "dossier/b.txt"))
        #expect(second.method == 8 && second.uncompressedSize == 5_000 && second.compressedSize < 5_000)
        #expect(index.entry(named: "absent") == nil)
    }

    @Test("Un commentaire d'archive est toléré")
    func toleratesComment() throws {
        let archive = ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))], comment: Data("un commentaire".utf8))
        #expect(try Self.index(archive).entries.count == 1)
    }

    @Test("Archive vide (aucune entrée) : valide mais sans entrée")
    func emptyArchive() throws {
        #expect(try Self.index(ZipFixture.build([])).entries.isEmpty)
    }

    @Test("Pas une archive : vide, texte, hasard, en-tête OLE2")
    func notAnArchive() {
        Self.expectFailure(Data(), .notAnArchive)
        Self.expectFailure(Data("Bonjour tout le monde".utf8), .notAnArchive)
        Self.expectFailure(Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }), .notAnArchive)
        Self.expectFailure(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 600), .notAnArchive)
    }

    @Test("Archive tronquée : la fin du répertoire est introuvable", arguments: [1, 10, 22, 60, 200])
    func truncated(cut: Int) throws {
        let archive = ZipFixture.build([
            .init(name: "a.txt", data: Data(repeating: 0x41, count: 4_000)),
            .init(name: "b.txt", data: Data(repeating: 0x42, count: 4_000)),
        ])
        Self.expectFailure(archive.prefix(archive.count - cut), .notAnArchive)
    }

    @Test("Décalage du répertoire hors du fichier : refusé")
    func directoryOffsetOutOfRange() {
        var archive = ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])
        let eocd = archive.count - 22
        archive.replaceSubrange((eocd + 16)..<(eocd + 20), with: ZipFixture.le32(0x00FF_0000))
        Self.expectFailure(archive, .malformed)
    }

    @Test("Nombre d'entrées annoncé incompatible avec la taille du répertoire : refusé")
    func entryCountLies() {
        var archive = ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])
        let eocd = archive.count - 22
        archive.replaceSubrange((eocd + 10)..<(eocd + 12), with: ZipFixture.le16(5_000))
        archive.replaceSubrange((eocd + 8)..<(eocd + 10), with: ZipFixture.le16(5_000))
        Self.expectFailure(archive, .malformed)
    }

    @Test("Plus d'entrées que le plafond : refusé sans lire le répertoire")
    func tooManyEntries() {
        var archive = ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])
        let eocd = archive.count - 22
        archive.replaceSubrange((eocd + 10)..<(eocd + 12), with: ZipFixture.le16(UInt16(ZipArchiveIndex.maxEntryCount + 1)))
        archive.replaceSubrange((eocd + 8)..<(eocd + 10), with: ZipFixture.le16(UInt16(ZipArchiveIndex.maxEntryCount + 1)))
        Self.expectFailure(archive, .tooLarge)
    }

    @Test("ZIP64 et archives en plusieurs disques : non pris en charge")
    func zip64AndMultiDisk() {
        var zip64 = ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])
        var eocd = zip64.count - 22
        zip64.replaceSubrange((eocd + 16)..<(eocd + 20), with: ZipFixture.le32(0xFFFF_FFFF))
        Self.expectFailure(zip64, .unsupported)

        var multi = ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])
        eocd = multi.count - 22
        multi.replaceSubrange((eocd + 4)..<(eocd + 6), with: ZipFixture.le16(1))
        Self.expectFailure(multi, .unsupported)
    }

    @Test("Noms piégés (remontée de dossier, chemin absolu, antislash, nul, vide) : toute l'archive est refusée",
          arguments: ["../../etc/passwd", "/etc/passwd", "word\\document.xml", "a/../../b", "x\u{0}y", "dossier/./../../z", "C:/windows/x"])
    func unsafeNames(name: String) {
        let archive = ZipFixture.build([
            .init(name: "word/document.xml", data: Data("<a/>".utf8)),
            .init(name: name, data: Data("piège".utf8)),
        ])
        Self.expectFailure(archive, .malformed)
    }

    @Test("Un nom vide est refusé")
    func emptyName() {
        Self.expectFailure(ZipFixture.build([.init(name: "", data: Data("x".utf8))]), .malformed)
    }

    @Test("Deux entrées de même nom : refusé (laquelle lire ?)")
    func duplicateNames() {
        let archive = ZipFixture.build([
            .init(name: "word/document.xml", data: Data("<a/>".utf8)),
            .init(name: "word/document.xml", data: Data("<b/>".utf8)),
        ])
        Self.expectFailure(archive, .malformed)
    }

    @Test("Les noms avec accents (UTF-8) sont lus")
    func utf8Names() throws {
        let archive = ZipFixture.build([.init(name: "dossier/é.txt", data: Data("x".utf8))])
        #expect(try Self.index(archive).entry(named: "dossier/é.txt") != nil)
    }

    // MARK: Données d'une entrée

    @Test("Plage des données : après l'en-tête local, avant le répertoire central")
    func dataRange() throws {
        let archive = ZipFixture.build([.init(name: "a.txt", data: Data("bonjour".utf8), method: 0)])
        let source = ZipDataSource(archive)
        let index = try ZipArchiveIndex(source: source)
        let entry = try #require(index.entry(named: "a.txt"))
        let range = try index.dataRange(of: entry, in: source)
        #expect(Data(archive[Int(range.lowerBound)..<Int(range.upperBound)]) == Data("bonjour".utf8))
    }

    @Test("Taille compressée mensongère (déborde sur le répertoire ou le fichier) : refusé")
    func compressedSizeLies() throws {
        let archive = ZipFixture.build([.init(name: "a.txt", data: Data("bonjour".utf8), method: 0, declaredCompressedSize: 9_999_999)])
        let source = ZipDataSource(archive)
        let index = try ZipArchiveIndex(source: source)
        let entry = try #require(index.entry(named: "a.txt"))
        #expect(throws: ZipArchiveError.malformed) { try index.dataRange(of: entry, in: source) }
    }

    @Test("Nom de l'en-tête local différent de celui du répertoire : refusé")
    func localNameMismatch() throws {
        let archive = ZipFixture.build([.init(name: "word/document.xml", data: Data("<a/>".utf8), method: 0, localNameOverride: "word/autre.xml")])
        let source = ZipDataSource(archive)
        let index = try ZipArchiveIndex(source: source)
        let entry = try #require(index.entry(named: "word/document.xml"))
        #expect(throws: ZipArchiveError.malformed) { try index.dataRange(of: entry, in: source) }
    }

    @Test("Décalage d'en-tête local hors du fichier : refusé")
    func localOffsetOutOfRange() throws {
        var archive = ZipFixture.build([.init(name: "a.txt", data: Data("bonjour".utf8), method: 0)])
        // Répertoire central : décalage de l'en-tête local à l'octet 42 de l'entrée.
        let eocd = archive.count - 22
        let directoryOffset = Int(archive[eocd + 16]) | Int(archive[eocd + 17]) << 8 | Int(archive[eocd + 18]) << 16
        archive.replaceSubrange((directoryOffset + 42)..<(directoryOffset + 46), with: ZipFixture.le32(0x7FFF_FFF0))
        let source = ZipDataSource(archive)
        #expect(throws: ZipArchiveError.malformed) {
            let index = try ZipArchiveIndex(source: source)
            let entry = try #require(index.entry(named: "a.txt"))
            _ = try index.dataRange(of: entry, in: source)
        }
    }

    // MARK: Reconnaissance d'un document Word

    @Test("Un .docx a [Content_Types].xml ET word/document.xml ; un .xlsx, un .odt ou un ZIP quelconque non")
    func recognizesWordDocument() throws {
        #expect(try Self.index(DocxFixture.make(paragraphs: ["x"])).isWordDocument)
        let xlsx = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "xl/workbook.xml", data: Data("<a/>".utf8)),
        ])
        #expect(try !Self.index(xlsx).isWordDocument)
        let odt = ZipFixture.build([
            .init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.text".utf8), method: 0),
            .init(name: "content.xml", data: Data("<a/>".utf8)),
        ])
        #expect(try !Self.index(odt).isWordDocument)
        #expect(try !Self.index(ZipFixture.build([.init(name: "a.txt", data: Data("x".utf8))])).isWordDocument)
    }

    @Test("Source fichier : la lecture se fait par morceaux, un fichier de 300 Mo à queue valide ne coûte rien")
    func fileSourceDoesNotLoadWholeFile() throws {
        let folder = try TestFiles.makeFolder("zip-sparse")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = ZipFixture.build([.init(name: "word/document.xml", data: Data("<a/>".utf8))])
        // Un fichier creux : 300 Mo de vide, puis l'archive (les décalages du répertoire sont donc faux, c'est voulu :
        // on vérifie seulement qu'ouvrir et chercher la fin ne charge pas le fichier).
        let url = folder.appendingPathComponent("gros.docx")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 300 * 1_024 * 1_024)
        try handle.seekToEnd()
        try handle.write(contentsOf: archive)
        try handle.close()
        let source = try ZipFileSource(url: url)
        #expect(source.byteCount == UInt64(300 * 1_024 * 1_024 + archive.count))
        #expect(throws: ZipArchiveError.self) { _ = try ZipArchiveIndex(source: source) }
    }
}
