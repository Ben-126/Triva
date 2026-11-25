//
//  DocxTextReader.swift
//  Triva
//
//  Mission W (décision de Ben, 25/11/2026) : lire le texte d'un document Word `.docx`, sur iPhone, iPad, iPhone Duo et
//  Mac, avec UN SEUL comportement. `NSAttributedString` sait lire le .docx sur macOS seulement (vérifié dans le SDK
//  iOS 27 : aucun type « Office Open XML » côté UIKit) ; un .docx est un ZIP, lu ici avec les frameworks d'Apple :
//  répertoire central (`ZipArchiveIndex`) → DEFLATE par blocs (`ZipEntryReader`, Compression) → `XMLParser`
//  (`WordTextCollector`). Aucune dépendance tierce.
//
//  Le fichier est une entrée HOSTILE : voir les plafonds de `Limits`, `WordXMLInputStream` (DOCTYPE, délai, annulation)
//  et `ZipEntryReader` (taille annoncée jamais crue). La lecture s'arrête dès que la limite de caractères est atteinte :
//  un gros document n'est jamais décompressé en entier.
//
//  Limites assumées : le corps est `word/document.xml` (le nom de toutes les applications courantes, sans passer par
//  `_rels/.rels`) ; en-têtes, pieds de page, commentaires, zones de formes dessinées et texte des images ne sont pas lus ;
//  les notes de bas de page et de fin sont ajoutées après le corps.
//

import Foundation

nonisolated struct DocxContent: Sendable, Equatable {
    /// Texte normalisé : paragraphes séparés par `\n`, cellules d'un tableau par une tabulation.
    let text: String
    /// Seul le début du document a été lu (limite de caractères atteinte).
    let isTruncated: Bool
    /// Octets de XML décompressés pour y arriver (diagnostic : prouve qu'un gros document n'est pas lu en entier).
    let inflatedByteCount: UInt64
}

nonisolated struct DocxTextReader: Sendable {
    /// Plafonds de lecture. Mêmes ordres de grandeur que le PDF : 200 Mo de fichier (comme la copie du coffre et le partage).
    struct Limits: Sendable, Equatable {
        /// Taille du fichier .docx lui-même.
        var maxFileByteCount: Int
        /// Taille décompressée d'une entrée lue (corps, notes). Un corps de 64 Mo de XML représente des centaines de pages.
        var maxEntryByteCount: Int
        /// Durée totale de lecture. Un document sain s'analyse en quelques centaines de millisecondes.
        var maxDuration: Duration
    }

    static let defaultLimits = Limits(maxFileByteCount: 200 * 1_024 * 1_024, maxEntryByteCount: 64 * 1_024 * 1_024, maxDuration: .seconds(10))

    private static let bodyPartName = "word/document.xml"
    private static let notePartNames = ["word/footnotes.xml", "word/endnotes.xml"]
    private static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    let limits: Limits

    init(limits: Limits = DocxTextReader.defaultLimits) {
        self.limits = limits
    }

    // MARK: - Points d'entrée

    /// Lit un fichier sur disque, par morceaux (jamais chargé en mémoire).
    func read(fileAt url: URL, characterLimit: Int) throws -> DocxContent {
        let source: ZipFileSource
        do {
            source = try ZipFileSource(url: url)
        } catch {
            throw AttachmentExtractionError.fileUnreadable
        }
        return try read(source: source, characterLimit: characterLimit)
    }

    /// Lit des octets déjà en mémoire (tests, données reçues d'ailleurs).
    func read(data: Data, characterLimit: Int) throws -> DocxContent {
        try read(source: ZipDataSource(data), characterLimit: characterLimit)
    }

    // MARK: - Lecture

    private func read(source: any ZipByteSource, characterLimit: Int) throws -> DocxContent {
        guard source.byteCount <= UInt64(limits.maxFileByteCount) else {
            throw AttachmentExtractionError.fileTooLarge(
                byteCount: Int(clamping: source.byteCount), maximumByteCount: limits.maxFileByteCount
            )
        }
        try rejectCompoundFile(source)
        let deadline = ContinuousClock.now + limits.maxDuration
        let index = try Self.index(of: source)
        guard index.isWordDocument, let body = index.entry(named: Self.bodyPartName) else {
            throw AttachmentExtractionError.invalidDocx
        }
        let limit = max(1, characterLimit)

        let main = try readPart(body, of: index, in: source, deadline: deadline, budget: limit + 1)
        var text = main.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isTruncated = main.reachedBudget
        var inflated = main.inflatedByteCount

        if !main.reachedBudget {
            let notes = try readNotes(of: index, in: source, deadline: deadline, budget: limit + 1 - text.count)
            inflated += notes.inflatedByteCount
            isTruncated = isTruncated || notes.reachedBudget
            if !notes.text.isEmpty { text = text.isEmpty ? notes.text : text + "\n\n" + notes.text }
        }

        let normalized = AttachmentTextExtractor.normalizedText(text)
        guard !normalized.isEmpty else { throw AttachmentExtractionError.noTextInDocument }
        let bounded = AttachmentTextExtractor.truncatedAtWordBoundary(normalized, maxCharacterCount: limit)
        return DocxContent(text: bounded.text, isTruncated: isTruncated || bounded.wasTruncated, inflatedByteCount: inflated)
    }

    /// Un fichier .docx protégé par mot de passe est un conteneur OLE2, comme un ancien .doc : même en-tête, même message.
    private func rejectCompoundFile(_ source: any ZipByteSource) throws {
        let head = (try? source.read(at: 0, length: Self.compoundFileSignature.count)) ?? Data()
        if Array(head) == Self.compoundFileSignature { throw AttachmentExtractionError.protectedOrLegacyWord }
    }

    private static func index(of source: any ZipByteSource) throws -> ZipArchiveIndex {
        do {
            return try ZipArchiveIndex(source: source)
        } catch ZipArchiveError.tooLarge {
            throw AttachmentExtractionError.docxTooLarge
        } catch {
            throw AttachmentExtractionError.invalidDocx
        }
    }

    // MARK: - Une entrée

    private struct PartText {
        let text: String
        let reachedBudget: Bool
        let inflatedByteCount: UInt64
    }

    /// Notes de bas de page puis de fin, au mieux : une note abîmée ou piégée est IGNORÉE, jamais fatale au corps
    /// (sauf annulation de la tâche, relayée).
    private func readNotes(
        of index: ZipArchiveIndex, in source: any ZipByteSource, deadline: ContinuousClock.Instant, budget: Int
    ) throws -> PartText {
        var pieces: [String] = []
        var remaining = budget
        var inflated: UInt64 = 0
        var reachedBudget = false
        for name in Self.notePartNames {
            guard remaining > 0, let entry = index.entry(named: name), !entry.isDirectory else { continue }
            do {
                let part = try readPart(entry, of: index, in: source, deadline: deadline, budget: remaining)
                inflated += part.inflatedByteCount
                reachedBudget = reachedBudget || part.reachedBudget
                let cleaned = AttachmentTextExtractor.normalizedText(part.text)
                if !cleaned.isEmpty {
                    pieces.append(cleaned)
                    remaining -= cleaned.count + 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        if remaining <= 0 { reachedBudget = true }
        return PartText(text: pieces.joined(separator: "\n"), reachedBudget: reachedBudget, inflatedByteCount: inflated)
    }

    private func readPart(
        _ entry: ZipEntry, of index: ZipArchiveIndex, in source: any ZipByteSource,
        deadline: ContinuousClock.Instant, budget: Int
    ) throws -> PartText {
        if entry.isEncrypted { throw AttachmentExtractionError.protectedOrLegacyWord }
        guard !entry.isDirectory, entry.method == 0 || entry.method == 8 else { throw AttachmentExtractionError.invalidDocx }
        // Taille annoncée : un plafond dépassé est refusé AVANT toute décompression (la vraie sortie reste bornée plus bas).
        guard entry.uncompressedSize <= UInt64(limits.maxEntryByteCount) else { throw AttachmentExtractionError.docxTooLarge }

        let entryReader: ZipEntryReader
        do {
            let range = try index.dataRange(of: entry, in: source)
            entryReader = try ZipEntryReader(source: source, entry: entry, range: range, maxOutputByteCount: UInt64(limits.maxEntryByteCount))
        } catch {
            throw AttachmentExtractionError.invalidDocx
        }
        let stream = WordXMLInputStream(entryReader: entryReader, deadline: deadline)
        let collector = WordTextCollector(characterBudget: budget, stream: stream)
        let parser = XMLParser(stream: stream)
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()

        if let failure = stream.failure { throw Self.error(for: failure) }
        if collector.sawDeclaration { throw AttachmentExtractionError.invalidDocx }
        guard collector.reachedBudget || parsed else { throw AttachmentExtractionError.invalidDocx }
        return PartText(text: collector.collectedText, reachedBudget: collector.reachedBudget, inflatedByteCount: stream.inflatedByteCount)
    }

    private static func error(for failure: WordXMLInputStream.Failure) -> any Error {
        switch failure {
        case .tooLarge, .timedOut: AttachmentExtractionError.docxTooLarge
        case .cancelled: CancellationError()
        case .hostile, .corrupt: AttachmentExtractionError.invalidDocx
        }
    }
}
