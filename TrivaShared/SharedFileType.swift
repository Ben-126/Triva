//
//  SharedFileType.swift
//  TrivaShared
//
//  Chantier 2.1 (mission E) : les fichiers que l'extension de partage accepte (PDF, Word .docx et images), reconnus par
//  leurs PREMIERS OCTETS (le .docx : par son répertoire central, voir `detect(fileAt:)`). Un fichier venu d'une autre app est une entrée externe : ni son nom, ni son extension, ni le type
//  annoncé par l'app source ne font foi. Liste fermée, alignée sur `AttachmentKind` (un test le garantit).
//
//  Compilé dans l'app ET dans l'extension : Foundation seulement, aucune lecture complète d'un fichier (la mémoire
//  d'une extension est très limitée).
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum SharedFileType: String, Codable, Sendable, CaseIterable {
    case pdf, docx, png, jpeg, gif, bmp, tiff, webp, heic, heif

    /// Identifiant système du .docx, déclaré par macOS et iOS ; à défaut, celui de l'extension `docx`.
    static let docxContentType: UTType? = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx")

    /// Combien d'octets de tête on lit : la spécification PDF tolère jusqu'à 1 024 octets avant `%PDF-`.
    static let headerLength = 1_024

    private static let megabyte = 1_024 * 1_024

    /// Explicite : un nouveau document (comme le .docx) ne doit jamais être pris pour une image (plafond de 50 Mo, nom « Image »).
    var isImage: Bool {
        switch self {
        case .pdf, .docx: false
        case .png, .jpeg, .gif, .bmp, .tiff, .webp, .heic, .heif: true
        }
    }

    /// Nature affichée dans la feuille de partage (« PDF · 2 Mo »).
    var kindLabel: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word"
        default: "Image"
        }
    }

    /// Extension du nom de fichier d'un fichier de ce type.
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    /// Taille au-delà de laquelle le fichier est refusé : 200 Mo pour un PDF ou un .docx (lus par morceaux, jamais en
    /// entier), 50 Mo pour une image.
    var maxByteCount: Int { isImage ? 50 * Self.megabyte : 200 * Self.megabyte }

    // MARK: Reconnaissance

    /// Le type d'après les octets de tête, ou `nil` (exécutable, texte, archive, AVIF, vide…).
    /// Un .docx n'est PAS reconnu ici : c'est une archive ZIP (`PK`), et seul son répertoire central, à la FIN du fichier,
    /// dit si c'est un document Word (`detect(fileAt:)`).
    static func detect(header: Data) -> SharedFileType? {
        let bytes = [UInt8](header.prefix(headerLength))
        if let pdf = detectPDF(bytes) { return pdf }
        if let heif = detectISOBase(bytes) { return heif }
        if starts(bytes, with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts(bytes, with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(bytes, with: Array("GIF87a".utf8)) || starts(bytes, with: Array("GIF89a".utf8)) { return .gif }
        if starts(bytes, with: [0x49, 0x49, 0x2A, 0x00]) || starts(bytes, with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts(bytes, with: Array("BM".utf8)) { return .bmp }
        if starts(bytes, with: Array("RIFF".utf8)), bytes.count >= 12, Array(bytes[8..<12]) == Array("WEBP".utf8) { return .webp }
        return nil
    }

    /// Le type d'un fichier sur disque : seule sa tête est lue, plus, pour une archive ZIP, son répertoire central (borné à
    /// quelques Mo, jamais une décompression). `nil` si le fichier est absent, illisible ou d'un autre type.
    static func detect(fileAt url: URL) -> SharedFileType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerLength) else { return nil }
        if let known = detect(header: header) { return known }
        return starts([UInt8](header), with: zipSignature) && isWordDocument(at: url) ? .docx : nil
    }

    // MARK: Interne

    private static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Un ZIP qui contient `[Content_Types].xml` ET `word/document.xml`. Un classeur, une présentation, un ODT ou un ZIP
    /// quelconque, même nommé « .docx », n'en est pas un.
    private static func isWordDocument(at url: URL) -> Bool {
        guard let source = try? ZipFileSource(url: url), let index = try? ZipArchiveIndex(source: source) else { return false }
        return index.isWordDocument
    }

    private static func starts(_ bytes: [UInt8], with prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && Array(bytes[0..<prefix.count]) == prefix
    }

    private static func detectPDF(_ bytes: [UInt8]) -> SharedFileType? {
        let marker = Array("%PDF-".utf8)
        guard bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) where bytes[start] == marker[0] {
            if Array(bytes[start..<(start + marker.count)]) == marker { return .pdf }
        }
        return nil
    }

    /// HEIC et HEIF : une boîte `ftyp` dont la marque est celle d'une image HEVC (`heic`…) ou d'une image HEIF
    /// générique (`mif1`, `msf1`). AVIF (`avif`) est refusé : Vision ne le lit pas.
    private static func detectISOBase(_ bytes: [UInt8]) -> SharedFileType? {
        guard bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return nil }
        switch String(decoding: bytes[8..<12], as: UTF8.self) {
        case "heic", "heix", "hevc", "hevx", "heim", "heis": return .heic
        case "mif1", "msf1": return .heif
        default: return nil
        }
    }
}

// MARK: - Nom de fichier

/// Nom affiché d'un fichier partagé : jamais un chemin, jamais de caractère de contrôle ni de sens d'écriture, et
/// l'extension est celle du type RÉEL du fichier (`AttachmentKind` classe par extension : un PNG nommé `.pdf` ne
/// doit pas partir vers le lecteur de PDF).
nonisolated enum SharedFileName {
    static let maxStemLength = 80

    private static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    static func sanitized(_ raw: String?, type: SharedFileType) -> String {
        let fallback = type.isImage ? "Image" : "Document"
        let lastComponent = (raw ?? "").replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let withoutExtension = (lastComponent as NSString).deletingPathExtension
        let cleaned = clean(withoutExtension)
        let stem = cleaned.isEmpty ? fallback : cleaned
        return "\(stem).\(type.fileExtension)"
    }

    private static func clean(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars.prefix(1_000) {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: continue
            default: break
            }
            if forbidden.contains(Character(scalar)) { continue }
            kept.append(scalar)
        }
        var stem = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") { stem.removeFirst() }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stem.count > maxStemLength else { return stem }
        return String(stem.prefix(maxStemLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
