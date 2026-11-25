//
//  ZipFixture.swift
//  TrivaTests
//
//  Mission W (lecture des .docx) : construit des archives ZIP et des fichiers .docx EN MÉMOIRE, y compris hostiles
//  (tailles mensongères, chemins piégés, noms en double, archive tronquée, bombe de décompression). Aucun binaire n'est
//  versionné : le dépôt est public, et chaque cas est lisible dans le test qui l'utilise.
//

import Compression
import Foundation

enum ZipFixture {
    /// Une entrée à écrire. Les champs `declared…` et `rawCompressed` servent à fabriquer des archives qui MENTENT.
    struct Entry {
        var name: String
        /// Contenu non compressé (ignoré si `rawCompressed` est fourni).
        var data: Data = Data()
        /// 0 = stocké, 8 = DEFLATE, autre = méthode non prise en charge.
        var method: UInt16 = 8
        var flags: UInt16 = 0
        var declaredUncompressedSize: UInt32?
        var declaredCompressedSize: UInt32?
        /// Octets écrits tels quels à la place de la compression de `data`.
        var rawCompressed: Data?
        /// Nom écrit dans l'en-tête local, s'il doit différer de celui du répertoire central.
        var localNameOverride: String?
    }

    /// Archive complète : entrées, répertoire central, fin de répertoire.
    static func build(_ entries: [Entry], comment: Data = Data()) -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let payload = entry.rawCompressed ?? (entry.method == 8 ? deflate(entry.data) : entry.data)
            let uncompressed = entry.declaredUncompressedSize ?? UInt32(entry.data.count)
            let compressed = entry.declaredCompressedSize ?? UInt32(payload.count)
            let offset = UInt32(body.count)
            let crc = crc32(entry.data)
            let localName = Data((entry.localNameOverride ?? entry.name).utf8)
            let centralName = Data(entry.name.utf8)

            body.append(le32(0x0403_4B50))
            body.append(le16(20)); body.append(le16(entry.flags)); body.append(le16(entry.method))
            body.append(le16(0)); body.append(le16(0x21))
            body.append(le32(crc)); body.append(le32(compressed)); body.append(le32(uncompressed))
            body.append(le16(UInt16(localName.count))); body.append(le16(0))
            body.append(localName); body.append(payload)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(entry.flags)); directory.append(le16(entry.method))
            directory.append(le16(0)); directory.append(le16(0x21))
            directory.append(le32(crc)); directory.append(le32(compressed)); directory.append(le32(uncompressed))
            directory.append(le16(UInt16(centralName.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0))
            directory.append(le32(offset)); directory.append(centralName)
        }
        var archive = body
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4B50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(entries.count))); archive.append(le16(UInt16(entries.count)))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(directoryOffset))
        archive.append(le16(UInt16(comment.count))); archive.append(comment)
        return archive
    }

    // MARK: - Compression (DEFLATE brut, comme le format ZIP)

    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = data.count + data.count / 10 + 1_024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(written > 0, "compression de test impossible")
        return output.prefix(written)
    }

    /// DEFLATE d'un motif répété `repeatCount` fois, sans jamais construire le résultat décompressé en mémoire :
    /// sert à fabriquer une bombe (centaines de Mo décompressés pour quelques centaines de Ko).
    static func deflateRepeating(_ pattern: Data, repeatCount: Int) -> Data {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        precondition(compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK)
        defer { compression_stream_destroy(&stream) }
        // Un bloc de motifs (≈ 1 Mo) réutilisé tant qu'il en reste à écrire.
        let perBlock = max(1, (1 << 20) / max(1, pattern.count))
        var block = Data()
        for _ in 0..<perBlock { block.append(pattern) }
        var output = Data()
        var scratch = [UInt8](repeating: 0, count: 64 * 1_024)
        var remaining = repeatCount
        while remaining > 0 {
            let count = min(remaining, perBlock)
            let chunk = count == perBlock ? block : Data(block.prefix(count * pattern.count))
            remaining -= count
            let isLast = remaining == 0
            chunk.withUnsafeBytes { source in
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = chunk.count
                repeat {
                    scratch.withUnsafeMutableBufferPointer { buffer in
                        stream.dst_ptr = buffer.baseAddress!
                        stream.dst_size = buffer.count
                        _ = compression_stream_process(&stream, isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                        output.append(buffer.baseAddress!, count: buffer.count - stream.dst_size)
                    }
                } while stream.src_size > 0 || stream.dst_size == 0
            }
        }
        return output
    }

    // MARK: - CRC-32 et petits entiers

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1) }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}

/// Fichiers .docx de test : le strict nécessaire d'un vrai document Word (types de contenu, relations, corps).
enum DocxFixture {
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>
    """

    /// Enveloppe d'un corps (`<w:p>…`) dans un `<w:document>`.
    static func documentXML(body: String, extraNamespaces: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordNamespace)" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \(extraNamespaces)><w:body>\(body)</w:body></w:document>
        """
    }

    static func paragraph(_ text: String) -> String {
        "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped(text))</w:t></w:r></w:p>"
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Un .docx valide dont le corps est `body`. `parts` ajoute d'autres fichiers (notes de bas de page…).
    static func make(body: String, parts: [(name: String, xml: String)] = [], method: UInt16 = 8) -> Data {
        var entries: [ZipFixture.Entry] = [
            .init(name: "[Content_Types].xml", data: Data(contentTypes.utf8), method: method),
            .init(name: "word/document.xml", data: Data(documentXML(body: body).utf8), method: method),
        ]
        entries += parts.map { .init(name: $0.name, data: Data($0.xml.utf8), method: method) }
        return ZipFixture.build(entries)
    }

    static func make(paragraphs: [String], method: UInt16 = 8) -> Data {
        make(body: paragraphs.map(paragraph).joined(), method: method)
    }

    /// Un .docx dont `word/document.xml` est exactement `xml` (pour les fichiers hostiles).
    static func make(rawDocumentXML xml: String, method: UInt16 = 8) -> Data {
        ZipFixture.build([
            .init(name: "[Content_Types].xml", data: Data(contentTypes.utf8), method: method),
            .init(name: "word/document.xml", data: Data(xml.utf8), method: method),
        ])
    }
}
