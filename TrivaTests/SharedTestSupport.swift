//
//  SharedTestSupport.swift
//  TrivaTests
//
//  Chantier 2.1 (mission E) : fichiers et horloge de test pour la boîte de partage.
//

import Foundation

/// Horloge réglable, lisible depuis n'importe quel contexte.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var date: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Octets d'en-tête reconnaissables, complétés par du remplissage.
enum SampleBytes {
    static func pdf(padding: Int = 64) -> Data { Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: padding) }
    static func png(padding: Int = 64) -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: padding) }
    static func jpeg(padding: Int = 64) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: padding) }
    static func gif(padding: Int = 64) -> Data { Data("GIF89a".utf8) + Data(repeating: 0, count: padding) }
    static func bmp(padding: Int = 64) -> Data { Data("BM".utf8) + Data(repeating: 0, count: padding) }
    static func tiffLittle(padding: Int = 64) -> Data { Data([0x49, 0x49, 0x2A, 0x00]) + Data(repeating: 0, count: padding) }
    static func tiffBig(padding: Int = 64) -> Data { Data([0x4D, 0x4D, 0x00, 0x2A]) + Data(repeating: 0, count: padding) }
    static func webp(padding: Int = 64) -> Data { Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8) + Data(repeating: 0, count: padding) }
    static func heic(brand: String = "heic", padding: Int = 64) -> Data {
        Data([0, 0, 0, 0x18]) + Data("ftyp".utf8) + Data(brand.utf8) + Data(repeating: 0, count: padding)
    }
    /// Un exécutable Mach-O / Windows déguisé : jamais accepté.
    static func executable() -> Data { Data("MZ".utf8) + Data(repeating: 0x90, count: 128) }
}

enum TestFiles {
    /// Dossier temporaire neuf (à supprimer par l'appelant, `defer`).
    static func makeFolder(_ label: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrivaTest-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    /// Fichier CREUX de `size` octets (aucun disque consommé) qui commence par `header`.
    @discardableResult
    static func writeSparse(header: Data, size: Int, named name: String, in folder: URL) throws -> URL {
        let url = try write(header, named: name, in: folder)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
        return url
    }
}
