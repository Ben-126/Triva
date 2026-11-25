//
//  DocxTextReaderTests.swift
//  TrivaTests
//
//  Mission W : lecture native (ZIP + XMLParser, aucune dépendance) du texte d'un document Word. Un seul comportement
//  sur iPhone, iPad, iPhone Duo et Mac. Les fichiers hostiles (bombe, entités, tronqué, chiffré, faux .docx) sont
//  refusés avec un motif fermé, sans jamais charger le document en mémoire ni dépasser les plafonds.
//

import Foundation
import Testing
@testable import Triva

@Suite("Word — lecture du texte d'un .docx")
struct DocxTextReaderTests {
    private let reader = DocxTextReader()

    private func text(of data: Data, limit: Int = 100_000) throws -> String {
        try reader.read(data: data, characterLimit: limit).text
    }

    private func expectFailure(
        _ data: Data,
        _ expected: AttachmentExtractionError,
        using reader: DocxTextReader? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            try (reader ?? self.reader).read(data: data, characterLimit: 100_000)
        }
    }

    // MARK: - Texte

    @Test("Les paragraphes sont séparés par une ligne, accents et espaces gardés")
    func paragraphs() throws {
        let data = DocxFixture.make(paragraphs: ["Première phrase déjà écrite.", "  Deuxième avec  espaces  ", "Troisième : à l'été, naïve, œuvre."])
        #expect(try text(of: data) == "Première phrase déjà écrite.\n  Deuxième avec  espaces\nTroisième : à l'été, naïve, œuvre.".trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Entités XML et références numériques décodées")
    func entities() throws {
        let body = "<w:p><w:r><w:t>A &amp; B &lt; C &#233; &#x1F600;</w:t></w:r></w:p>"
        #expect(try text(of: DocxFixture.make(body: body)) == "A & B < C é \u{1F600}")
    }

    @Test("Un fichier lu sur disque donne le même texte qu'en mémoire")
    func fromFile() throws {
        let folder = try TestFiles.makeFolder("docx-file")
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = DocxFixture.make(paragraphs: ["Bonjour le monde", "Deuxième ligne"])
        let url = try TestFiles.write(data, named: "cours.docx", in: folder)
        let fromFile = try reader.read(fileAt: url, characterLimit: 1_000)
        #expect(fromFile.text == (try text(of: data)))
        #expect(fromFile.text == "Bonjour le monde\nDeuxième ligne")
    }

    @Test("Entrées stockées (méthode 0) lues comme les compressées")
    func storedEntries() throws {
        #expect(try text(of: DocxFixture.make(paragraphs: ["Stocké sans compression"], method: 0)) == "Stocké sans compression")
    }

    @Test("Tabulations et sauts de ligne dans un passage ; les arrêts de tabulation d'un paragraphe ne comptent pas")
    func tabsAndBreaks() throws {
        let body = """
        <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="708"/><w:tab w:val="right" w:pos="9000"/></w:tabs></w:pPr>\
        <w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t><w:cr/><w:t>d</w:t><w:br w:type="page"/><w:t>e</w:t></w:r></w:p>
        """
        #expect(try text(of: DocxFixture.make(body: body)) == "a\tb\nc\nd\ne")
    }

    @Test("Tableau : cellules séparées par une tabulation, une ligne par rangée")
    func tables() throws {
        func cell(_ text: String) -> String { "<w:tc><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:tc>" }
        let body = """
        \(DocxFixture.paragraph("Avant"))\
        <w:tbl><w:tr>\(cell("A1"))\(cell("B1"))</w:tr><w:tr>\(cell("A2"))\(cell("B2"))</w:tr></w:tbl>\
        \(DocxFixture.paragraph("Après"))
        """
        #expect(try text(of: DocxFixture.make(body: body)) == "Avant\nA1\tB1\nA2\tB2\nAprès")
    }

    @Test("Tableau imbriqué et plusieurs paragraphes dans une cellule")
    func nestedTables() throws {
        let inner = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let body = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>un</w:t></w:r></w:p><w:p><w:r><w:t>deux</w:t></w:r></w:p>\(inner)<w:p/></w:tc><w:tc><w:p><w:r><w:t>fin</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let result = try text(of: DocxFixture.make(body: body))
        #expect(result.contains("un"))
        #expect(result.contains("deux"))
        #expect(result.contains("x"))
        #expect(result.contains("fin"))
        #expect(!result.contains("\n\n"))
    }

    @Test("Texte supprimé (suivi des modifications) ignoré, texte inséré gardé ; codes de champ ignorés")
    func trackedChangesAndFields() throws {
        let body = """
        <w:p><w:r><w:t>Garde </w:t></w:r><w:del w:id="1"><w:r><w:delText>supprimé</w:delText></w:r></w:del>\
        <w:ins w:id="2"><w:r><w:t>inséré </w:t></w:r></w:ins>\
        <w:r><w:fldChar w:fldCharType="begin"/><w:instrText> HYPERLINK "http://exemple.fr" </w:instrText><w:fldChar w:fldCharType="separate"/><w:t>lien</w:t><w:fldChar w:fldCharType="end"/></w:r></w:p>
        """
        #expect(try text(of: DocxFixture.make(body: body)) == "Garde inséré lien")
    }

    @Test("Zone de texte : lue une seule fois (la copie de repli de mc:AlternateContent est ignorée)")
    func textBoxFallbackIgnored() throws {
        let body = """
        <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><w:txbxContent><w:p><w:r><w:t>Dans la zone</w:t></w:r></w:p></w:txbxContent></w:drawing></mc:Choice>\
        <mc:Fallback><w:pict><w:txbxContent><w:p><w:r><w:t>Dans la zone</w:t></w:r></w:p></w:txbxContent></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>
        """
        let result = try text(of: DocxFixture.make(body: body))
        #expect(result == "Dans la zone")
    }

    @Test("Notes de bas de page et de fin lues après le corps ; séparateurs ignorés")
    func notes() throws {
        let footnotes = """
        <?xml version="1.0" encoding="UTF-8"?><w:footnotes xmlns:w="\(DocxFixture.wordNamespace)">\
        <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>\
        <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>\
        <w:footnote w:id="1"><w:p><w:r><w:footnoteRef/><w:t>Note de bas de page</w:t></w:r></w:p></w:footnote></w:footnotes>
        """
        let endnotes = """
        <?xml version="1.0" encoding="UTF-8"?><w:endnotes xmlns:w="\(DocxFixture.wordNamespace)">\
        <w:endnote w:id="1"><w:p><w:r><w:t>Note de fin</w:t></w:r></w:p></w:endnote></w:endnotes>
        """
        let data = DocxFixture.make(
            body: DocxFixture.paragraph("Corps du texte"),
            parts: [("word/footnotes.xml", footnotes), ("word/endnotes.xml", endnotes)]
        )
        #expect(try text(of: data) == "Corps du texte\n\nNote de bas de page\nNote de fin")
    }

    @Test("Notes abîmées ou piégées : ignorées, le corps est quand même lu")
    func brokenNotesAreIgnored() throws {
        let hostile = "<!DOCTYPE x [<!ENTITY a \"b\">]><w:footnotes xmlns:w=\"\(DocxFixture.wordNamespace)\"/>"
        let data = DocxFixture.make(
            body: DocxFixture.paragraph("Corps"),
            parts: [("word/footnotes.xml", hostile), ("word/endnotes.xml", "pas du xml <<<")]
        )
        #expect(try text(of: data) == "Corps")
    }

    @Test("Espace de noms « strict » (ISO 29500) accepté ; un autre espace de noms ne donne aucun texte")
    func strictNamespace() throws {
        let strict = "<w:document xmlns:w=\"http://purl.oclc.org/ooxml/wordprocessingml/main\"><w:body><w:p><w:r><w:t>Mode strict</w:t></w:r></w:p></w:body></w:document>"
        #expect(try text(of: DocxFixture.make(rawDocumentXML: strict)) == "Mode strict")
        let foreign = "<w:document xmlns:w=\"http://exemple.fr/autre\"><w:body><w:p><w:r><w:t>Pas du Word</w:t></w:r></w:p></w:body></w:document>"
        expectFailure(DocxFixture.make(rawDocumentXML: foreign), .noTextInDocument)
    }

    @Test("Préfixe d'espace de noms quelconque")
    func anyPrefix() throws {
        let xml = "<x:document xmlns:x=\"\(DocxFixture.wordNamespace)\"><x:body><x:p><x:r><x:t>Autre préfixe</x:t></x:r></x:p></x:body></x:document>"
        #expect(try text(of: DocxFixture.make(rawDocumentXML: xml)) == "Autre préfixe")
    }

    @Test("Document sans aucun texte : message dédié")
    func noText() {
        expectFailure(DocxFixture.make(body: "<w:p/><w:p><w:r><w:t>   </w:t></w:r></w:p>"), .noTextInDocument)
        expectFailure(DocxFixture.make(body: ""), .noTextInDocument)
    }

    // MARK: - Troncature et lecture en flux

    @Test("Troncature à la limite de caractères, sur une frontière de mot, signalée")
    func truncation() throws {
        let words = (1...400).map { "mot\($0)" }.joined(separator: " ")
        let content = try reader.read(data: DocxFixture.make(paragraphs: [words, words]), characterLimit: 100)
        #expect(content.isTruncated)
        #expect(content.text.count <= 100)
        #expect(content.text.hasPrefix("mot1 mot2 mot3"))
        #expect(!content.text.hasSuffix(" "))
        #expect(words.hasPrefix(content.text))
    }

    @Test("Sous la limite : pas de troncature")
    func noTruncation() throws {
        let content = try reader.read(data: DocxFixture.make(paragraphs: ["court"]), characterLimit: 100)
        #expect(!content.isTruncated)
    }

    @Test("Lecture en flux : un gros document n'est lu que jusqu'à la limite de caractères, jamais en entier")
    func readsOnlyWhatItNeeds() throws {
        let paragraph = DocxFixture.paragraph("Un paragraphe de remplissage assez long pour peser dans le fichier décompressé.")
        let bigBody = String(repeating: paragraph, count: 100_000)   // ≈ 11 Mo de XML
        let data = DocxFixture.make(body: bigBody)
        let started = ContinuousClock.now
        let content = try reader.read(data: data, characterLimit: 12_500)
        let elapsed = ContinuousClock.now - started
        #expect(content.isTruncated)
        #expect(content.text.count <= 12_500 && content.text.count > 12_000)
        #expect(content.inflatedByteCount < 2 * 1_024 * 1_024, "décompressé: \(content.inflatedByteCount) octets")
        #expect(elapsed < .seconds(2))
    }

    // MARK: - Fichiers hostiles

    @Test("Bombe : taille décompressée annoncée au-delà du plafond → refusée avant toute décompression")
    func declaredBombRefused() {
        let bomb = ZipFixture.deflateRepeating(Data("<w:p/>".utf8), repeatCount: 20_000_000)   // 120 Mo décompressés
        let archive = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "word/document.xml", method: 8, declaredUncompressedSize: 120_000_000, rawCompressed: bomb),
        ])
        #expect(archive.count < 2_000_000)
        let started = ContinuousClock.now
        expectFailure(archive, .docxTooLarge)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Bombe menteuse : taille annoncée minuscule, contenu énorme → arrêtée net, refusée")
    func lyingBombStopsEarly() {
        let payload = ZipFixture.deflateRepeating(Data("<w:p/>".utf8), repeatCount: 3_000_000)   // 18 Mo
        let archive = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "word/document.xml", method: 8, declaredUncompressedSize: 1_000, rawCompressed: payload),
        ])
        let started = ContinuousClock.now
        expectFailure(archive, .invalidDocx)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Plafond d'entrée réglable : refus au-delà")
    func entryLimit() {
        let small = DocxTextReader(limits: .init(maxFileByteCount: 1_000_000, maxEntryByteCount: 4_096, maxDuration: .seconds(5)))
        expectFailure(DocxFixture.make(paragraphs: [String(repeating: "mot ", count: 5_000)]), .docxTooLarge, using: small)
    }

    @Test("Fichier plus gros que le plafond de fichier : refusé")
    func fileLimit() {
        let tiny = DocxTextReader(limits: .init(maxFileByteCount: 200, maxEntryByteCount: 1_000_000, maxDuration: .seconds(5)))
        let data = DocxFixture.make(paragraphs: ["x"])
        #expect(throws: AttachmentExtractionError.fileTooLarge(byteCount: data.count, maximumByteCount: 200)) {
            try tiny.read(data: data, characterLimit: 1_000)
        }
    }

    @Test("Délai dépassé : refusé comme « trop complexe »")
    func timeout() {
        let instant = DocxTextReader(limits: .init(maxFileByteCount: 1_000_000, maxEntryByteCount: 1_000_000, maxDuration: .zero))
        expectFailure(DocxFixture.make(paragraphs: ["x"]), .docxTooLarge, using: instant)
    }

    @Test("Entités : « milliard de rires » refusé sans jamais être développé, vite")
    func billionLaughs() {
        let xml = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">\
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">\
        <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">]>\
        <w:document xmlns:w="\(DocxFixture.wordNamespace)"><w:body><w:p><w:r><w:t>&lol4;</w:t></w:r></w:p></w:body></w:document>
        """
        let started = ContinuousClock.now
        expectFailure(DocxFixture.make(rawDocumentXML: xml), .invalidDocx)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Entité externe (lecture d'un fichier local) refusée : rien ne fuit dans le texte")
    func externalEntity() {
        let xml = """
        <?xml version="1.0"?><!DOCTYPE d [<!ENTITY secret SYSTEM "file:///etc/hosts">]>\
        <w:document xmlns:w="\(DocxFixture.wordNamespace)"><w:body><w:p><w:r><w:t>&secret;</w:t></w:r></w:p></w:body></w:document>
        """
        expectFailure(DocxFixture.make(rawDocumentXML: xml), .invalidDocx)
    }

    @Test("DOCTYPE vide ou sans entité : refusé aussi (aucun document Word n'en contient)")
    func anyDoctypeRefused() {
        let xml = "<!DOCTYPE w:document><w:document xmlns:w=\"\(DocxFixture.wordNamespace)\"><w:body><w:p><w:r><w:t>x</w:t></w:r></w:p></w:body></w:document>"
        expectFailure(DocxFixture.make(rawDocumentXML: xml), .invalidDocx)
    }

    @Test("DOCTYPE à cheval sur deux blocs de lecture : repéré quand même", arguments: Array(65_520...65_545))
    func doctypeAcrossChunkBoundary(padding: Int) {
        let filler = "<!--" + String(repeating: "a", count: padding) + "-->"
        let xml = "<?xml version=\"1.0\"?>\(filler)<!DOCTYPE d [<!ENTITY e \"boum\">]><w:document xmlns:w=\"\(DocxFixture.wordNamespace)\"><w:body><w:p><w:r><w:t>&e;</w:t></w:r></w:p></w:body></w:document>"
        expectFailure(DocxFixture.make(rawDocumentXML: xml), .invalidDocx)
    }

    @Test("Imbrication démesurée : refusée, sans planter")
    func deepNesting() {
        let depth = 20_000
        let xml = "<w:document xmlns:w=\"\(DocxFixture.wordNamespace)\"><w:body>" + String(repeating: "<w:p>", count: depth)
            + "<w:r><w:t>x</w:t></w:r>" + String(repeating: "</w:p>", count: depth) + "</w:body></w:document>"
        expectFailure(DocxFixture.make(rawDocumentXML: xml), .invalidDocx)
    }

    @Test("XML mal formé : refusé")
    func malformedXML() {
        expectFailure(DocxFixture.make(rawDocumentXML: "<w:document xmlns:w=\"\(DocxFixture.wordNamespace)\"><w:body><w:p>"), .invalidDocx)
        expectFailure(DocxFixture.make(rawDocumentXML: "ceci n'est pas du XML"), .invalidDocx)
        expectFailure(DocxFixture.make(rawDocumentXML: "<a>&inconnue;</a>"), .invalidDocx)
    }

    @Test("Archive tronquée (téléchargement coupé) : refusée", arguments: [10, 100, 400])
    func truncatedArchive(cut: Int) {
        let data = DocxFixture.make(paragraphs: [String(repeating: "texte ", count: 2_000)])
        expectFailure(data.prefix(data.count - cut), .invalidDocx)
    }

    @Test("Entrée compressée coupée en plein milieu (répertoire intact) : refusée")
    func truncatedEntry() {
        let full = ZipFixture.deflate(Data(DocxFixture.documentXML(body: String(repeating: DocxFixture.paragraph("abc def ghi"), count: 2_000)).utf8))
        let archive = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "word/document.xml", data: Data(), method: 8, declaredUncompressedSize: 200_000, rawCompressed: full.prefix(full.count / 2)),
        ])
        expectFailure(archive, .invalidDocx)
    }

    @Test("Faux .docx : texte, hasard, PDF, vide")
    func fakeDocx() {
        expectFailure(Data("Bonjour, je suis un fichier texte.".utf8), .invalidDocx)
        expectFailure(Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) }), .invalidDocx)
        expectFailure(Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: 200), .invalidDocx)
        expectFailure(Data(), .invalidDocx)
    }

    @Test("En-tête OLE2 : document protégé par mot de passe OU ancien format .doc → message dédié")
    func ole2Header() {
        let ole2 = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 2_000)
        expectFailure(ole2, .protectedOrLegacyWord)
    }

    @Test("Entrée chiffrée dans le ZIP : refusée comme protégée")
    func encryptedEntry() {
        let archive = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "word/document.xml", data: Data(DocxFixture.documentXML(body: DocxFixture.paragraph("secret")).utf8), flags: 0x0001),
        ])
        expectFailure(archive, .protectedOrLegacyWord)
    }

    @Test("Méthode de compression inconnue (12 = bzip2) : refusée")
    func unsupportedMethod() {
        let archive = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "word/document.xml", data: Data("<a/>".utf8), method: 12),
        ])
        expectFailure(archive, .invalidDocx)
    }

    @Test("Noms de fichiers piégés ou en double : toute l'archive est refusée ; rien n'est jamais écrit sur le disque")
    func trappedNames() {
        for trap in ["../../evil.xml", "/etc/passwd", "word\\x"] {
            let archive = ZipFixture.build([
                .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
                .init(name: "word/document.xml", data: Data(DocxFixture.documentXML(body: DocxFixture.paragraph("ok")).utf8)),
                .init(name: trap, data: Data("x".utf8)),
            ])
            expectFailure(archive, .invalidDocx)
        }
        let duplicated = ZipFixture.build([
            .init(name: "word/document.xml", data: Data(DocxFixture.documentXML(body: DocxFixture.paragraph("un")).utf8)),
            .init(name: "word/document.xml", data: Data(DocxFixture.documentXML(body: DocxFixture.paragraph("deux")).utf8)),
        ])
        expectFailure(duplicated, .invalidDocx)
    }

    @Test("ZIP sans word/document.xml (classeur, présentation, ODT renommés) : refusé")
    func notAWordDocument() {
        let xlsx = ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(DocxFixture.contentTypes.utf8)),
            .init(name: "xl/workbook.xml", data: Data("<workbook/>".utf8)),
        ])
        expectFailure(xlsx, .invalidDocx)
        let odt = ZipFixture.build([
            .init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.text".utf8), method: 0),
            .init(name: "content.xml", data: Data("<office:document-content/>".utf8)),
        ])
        expectFailure(odt, .invalidDocx)
    }

    @Test("Tâche annulée : CancellationError, pas un motif de fichier")
    func cancellation() async {
        let reader = self.reader
        let data = DocxFixture.make(paragraphs: ["Bonjour"])
        let task = Task { () -> Result<DocxContent, any Error> in
            while !Task.isCancelled { await Task.yield() }
            return Result { try reader.read(data: data, characterLimit: 1_000) }
        }
        task.cancel()
        let result = await task.value
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
