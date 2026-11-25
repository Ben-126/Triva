//
//  ZipArchiveIndex.swift
//  TrivaShared
//
//  Mission W (lecture des .docx) : le répertoire central d'une archive ZIP, lu SANS jamais charger l'archive ni
//  décompresser quoi que ce soit. Compilé dans l'app ET dans l'extension de partage (qui s'en sert seulement pour
//  reconnaître un .docx : mémoire très limitée, Foundation seulement).
//
//  Principes : une archive est une entrée EXTERNE hostile.
//  - La fin du répertoire (EOCD) est cherchée dans les 65 557 derniers octets, pas dans tout le fichier.
//  - Aucune allocation n'est dimensionnée par une taille annoncée : le répertoire est plafonné (octets et entrées) AVANT
//    d'être lu, les tailles des entrées ne servent qu'à des comparaisons.
//  - Tout ce qui est incohérent refuse TOUTE l'archive : nom piégé, doublon, décalage hors du fichier, ZIP64.
//  - Rien n'est jamais extrait sur le disque : une entrée se cherche par son nom exact, donc un nom comme
//    `../../x` ne peut rien atteindre. Il est refusé quand même, par prudence.
//

import Foundation

// MARK: - Sources d'octets

/// Un conteneur d'octets à accès direct (un fichier lu par morceaux, ou des octets en mémoire pour les tests).
nonisolated protocol ZipByteSource {
    var byteCount: UInt64 { get }
    /// Au plus `length` octets à partir de `offset` (moins en fin de source). Lève si la lecture échoue.
    func read(at offset: UInt64, length: Int) throws -> Data
}

nonisolated struct ZipDataSource: ZipByteSource {
    private let data: Data

    init(_ data: Data) { self.data = data }

    var byteCount: UInt64 { UInt64(data.count) }

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard offset <= UInt64(data.count), length >= 0 else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = data.startIndex + min(data.count, Int(offset) + length)
        return Data(data[start..<end])
    }
}

/// Un fichier lu par morceaux (`FileHandle`), jamais en entier. Une instance par lecture, sur un seul fil.
nonisolated final class ZipFileSource: ZipByteSource {
    private let handle: FileHandle
    let byteCount: UInt64

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            byteCount = try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard offset <= byteCount, length > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

// MARK: - Répertoire central

nonisolated enum ZipArchiveError: Error, Equatable, Sendable {
    /// Pas d'archive ZIP : pas de fin de répertoire (fichier tronqué, texte, autre format).
    case notAnArchive
    /// Une archive qui se contredit (décalage hors du fichier, nom piégé, doublon, nom local différent).
    case malformed
    /// ZIP64, archive en plusieurs disques : ni l'un ni l'autre n'existe pour un document de bureautique courant.
    case unsupported
    /// Répertoire central ou nombre d'entrées au-delà des plafonds.
    case tooLarge
}

nonisolated struct ZipEntry: Equatable, Sendable {
    let name: String
    /// 0 = stocké, 8 = DEFLATE.
    let method: UInt16
    let flags: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64

    /// Bit 0 : entrée chiffrée. Bit 6 : chiffrement fort.
    var isEncrypted: Bool { flags & 0x0001 != 0 || flags & 0x0040 != 0 }
    var isDirectory: Bool { name.hasSuffix("/") }
}

nonisolated struct ZipArchiveIndex: Sendable {
    /// Un document Word courant a quelques dizaines d'entrées ; même avec beaucoup d'images, 20 000 est large.
    static let maxEntryCount = 20_000
    /// Un répertoire de 20 000 entrées aux noms longs tient dans moins de 4 Mo.
    static let maxDirectoryByteCount = 4 * 1_024 * 1_024

    private static let eocdLength = 22
    private static let maxCommentLength = 65_535
    private static let localHeaderLength = 30
    private static let centralHeaderLength = 46
    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50

    let entries: [String: ZipEntry]
    /// Début du répertoire central : les données des entrées doivent se terminer avant.
    let directoryOffset: UInt64
    let archiveByteCount: UInt64

    func entry(named name: String) -> ZipEntry? { entries[name] }

    /// Un document Word : `[Content_Types].xml` (paquet OPC) ET `word/document.xml` (le corps), tous deux des fichiers.
    var isWordDocument: Bool {
        guard let types = entries["[Content_Types].xml"], let body = entries["word/document.xml"] else { return false }
        return !types.isDirectory && !body.isDirectory
    }

    init(source: any ZipByteSource) throws {
        let size = source.byteCount
        let eocd = try Self.findEndOfDirectory(in: source, size: size)
        let totalEntries = Int(eocd.entryCount)
        guard totalEntries <= Self.maxEntryCount else { throw ZipArchiveError.tooLarge }
        guard eocd.directorySize <= UInt64(Self.maxDirectoryByteCount) else { throw ZipArchiveError.tooLarge }
        // Le répertoire se termine avant la fin de répertoire, et chaque entrée pèse au moins 46 octets.
        guard eocd.directoryOffset + eocd.directorySize <= eocd.position,
              UInt64(totalEntries) * UInt64(Self.centralHeaderLength) <= eocd.directorySize else {
            throw ZipArchiveError.malformed
        }
        let directory = try source.read(at: eocd.directoryOffset, length: Int(eocd.directorySize))
        guard directory.count == Int(eocd.directorySize) else { throw ZipArchiveError.malformed }

        entries = try Self.parseDirectory(directory, expectedCount: totalEntries, directoryOffset: eocd.directoryOffset)
        directoryOffset = eocd.directoryOffset
        archiveByteCount = size
    }

    // MARK: Données d'une entrée

    /// Où se trouvent les octets de l'entrée : après son en-tête local, avant le répertoire central, dans le fichier.
    /// Vérifie l'en-tête local (signature, même nom que le répertoire : un nom différent est une archive truquée).
    func dataRange(of entry: ZipEntry, in source: any ZipByteSource) throws -> Range<UInt64> {
        guard entry.localHeaderOffset + UInt64(Self.localHeaderLength) <= directoryOffset else { throw ZipArchiveError.malformed }
        let header = try source.read(at: entry.localHeaderOffset, length: Self.localHeaderLength)
        guard header.count == Self.localHeaderLength, Self.readUInt32(header, 0) == Self.localSignature else {
            throw ZipArchiveError.malformed
        }
        let nameLength = UInt64(Self.readUInt16(header, 26))
        let extraLength = UInt64(Self.readUInt16(header, 28))
        let nameStart = entry.localHeaderOffset + UInt64(Self.localHeaderLength)
        guard nameStart + nameLength <= directoryOffset else { throw ZipArchiveError.malformed }
        let localName = try source.read(at: nameStart, length: Int(nameLength))
        guard localName == Data(entry.name.utf8) else { throw ZipArchiveError.malformed }

        let start = nameStart + nameLength + extraLength
        let (end, overflow) = start.addingReportingOverflow(entry.compressedSize)
        guard !overflow, start <= end, end <= directoryOffset, end <= archiveByteCount else { throw ZipArchiveError.malformed }
        if entry.method == 0, entry.compressedSize != entry.uncompressedSize { throw ZipArchiveError.malformed }
        return start..<end
    }

    // MARK: Interne

    private struct EndOfDirectory {
        let position: UInt64
        let entryCount: UInt16
        let directorySize: UInt64
        let directoryOffset: UInt64
    }

    private static func findEndOfDirectory(in source: any ZipByteSource, size: UInt64) throws -> EndOfDirectory {
        guard size >= UInt64(eocdLength) else { throw ZipArchiveError.notAnArchive }
        let tailLength = Int(min(size, UInt64(eocdLength + maxCommentLength)))
        let tailStart = size - UInt64(tailLength)
        let tail: Data
        do { tail = try source.read(at: tailStart, length: tailLength) } catch { throw ZipArchiveError.notAnArchive }
        guard tail.count == tailLength else { throw ZipArchiveError.notAnArchive }

        // De la fin vers le début : la dernière fin de répertoire dont le commentaire tient dans le fichier.
        var position = tailLength - eocdLength
        while position >= 0 {
            if readUInt32(tail, position) == eocdSignature {
                let commentLength = Int(readUInt16(tail, position + 20))
                if position + eocdLength + commentLength <= tailLength {
                    return try parseEndOfDirectory(tail, at: position, absolutePosition: tailStart + UInt64(position))
                }
            }
            position -= 1
        }
        throw ZipArchiveError.notAnArchive
    }

    private static func parseEndOfDirectory(_ tail: Data, at position: Int, absolutePosition: UInt64) throws -> EndOfDirectory {
        let diskNumber = readUInt16(tail, position + 4)
        let directoryDisk = readUInt16(tail, position + 6)
        let entriesOnDisk = readUInt16(tail, position + 8)
        let totalEntries = readUInt16(tail, position + 10)
        let directorySize = readUInt32(tail, position + 12)
        let directoryOffset = readUInt32(tail, position + 16)
        // Valeurs « sentinelles » : les vraies sont dans l'extension ZIP64.
        if totalEntries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF { throw ZipArchiveError.unsupported }
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == totalEntries else { throw ZipArchiveError.unsupported }
        return EndOfDirectory(
            position: absolutePosition, entryCount: totalEntries,
            directorySize: UInt64(directorySize), directoryOffset: UInt64(directoryOffset)
        )
    }

    private static func parseDirectory(_ directory: Data, expectedCount: Int, directoryOffset: UInt64) throws -> [String: ZipEntry] {
        var entries: [String: ZipEntry] = [:]
        entries.reserveCapacity(expectedCount)
        var cursor = 0
        for _ in 0..<expectedCount {
            guard cursor + centralHeaderLength <= directory.count, readUInt32(directory, cursor) == centralSignature else {
                throw ZipArchiveError.malformed
            }
            let flags = readUInt16(directory, cursor + 8)
            let method = readUInt16(directory, cursor + 10)
            let compressedSize = readUInt32(directory, cursor + 20)
            let uncompressedSize = readUInt32(directory, cursor + 24)
            let nameLength = Int(readUInt16(directory, cursor + 28))
            let extraLength = Int(readUInt16(directory, cursor + 30))
            let commentLength = Int(readUInt16(directory, cursor + 32))
            let localOffset = readUInt32(directory, cursor + 42)
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipArchiveError.unsupported
            }
            let nameStart = cursor + centralHeaderLength
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= directory.count else { throw ZipArchiveError.malformed }

            let name = try decodedName(Data(directory[nameStart..<(nameStart + nameLength)]))
            guard isSafe(name), entries[name] == nil else { throw ZipArchiveError.malformed }
            guard UInt64(localOffset) < directoryOffset else { throw ZipArchiveError.malformed }
            entries[name] = ZipEntry(
                name: name, method: method, flags: flags,
                compressedSize: UInt64(compressedSize), uncompressedSize: UInt64(uncompressedSize),
                localHeaderOffset: UInt64(localOffset)
            )
            cursor = next
        }
        return entries
    }

    private static func decodedName(_ raw: Data) throws -> String {
        // UTF-8 (drapeau « bit 11 » ou usage courant) ; à défaut, le jeu historique des anciens outils.
        if let utf8 = String(data: raw, encoding: .utf8) { return utf8 }
        if let legacy = String(data: raw, encoding: .isoLatin1) { return legacy }
        throw ZipArchiveError.malformed
    }

    /// Nom sûr : non vide, relatif, sans antislash ni octet nul, sans composant `..` ni `.`.
    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\u{0}") else { return false }
        // Lettre de lecteur (« C:/… »).
        let scalars = Array(name.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":" { return false }
        for component in name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0) {
            if component == ".." || component == "." { return false }
        }
        return true
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
