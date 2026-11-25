//
//  WordXMLInputStream.swift
//  Triva
//
//  Mission W (lecture des .docx) : le flux d'octets que lit `XMLParser`. Il enveloppe `ZipEntryReader` et fait respecter
//  TOUTES les limites lui-même, parce que `XMLParser.abortParsing()` n'arrête PAS la lecture du flux (mesuré : l'analyseur
//  continue de vider le flux jusqu'au bout après l'abandon). Dès qu'une limite saute, `read` rend 0 (fin normale, arrêt
//  demandé par le collecteur) ou -1 (échec, motif dans `failure`).
//
//  Filtre de sécurité : tout octet `<!DOCTYPE` est refusé AVANT que l'analyseur ne le voie. Un document Word n'en
//  contient jamais ; c'est là que vivent les entités externes (lecture de fichiers locaux) et récursives (« milliard
//  de rires »). Les 8 derniers octets d'un bloc sont gardés pour repérer un marqueur coupé entre deux blocs.
//

import Foundation

nonisolated final class WordXMLInputStream: InputStream {
    enum Failure: Equatable {
        /// Déclaration de type de document (entités) : hostile.
        case hostile
        /// Archive tronquée, corrompue ou menteuse.
        case corrupt
        /// Plafond de taille décompressée dépassé.
        case tooLarge
        /// Délai dépassé.
        case timedOut
        case cancelled
    }

    /// Taille d'un bloc rendu à l'analyseur : celle des blocs compressés, pour borner le travail entre deux contrôles.
    private static let chunkByteCount = 64 * 1_024
    private static let doctypeMarker = Array("<!DOCTYPE".utf8)

    private let entryReader: ZipEntryReader
    private let deadline: ContinuousClock.Instant
    private var status: Stream.Status = .notOpen
    private var carried: [UInt8] = []
    private var stopRequested = false

    /// Premier motif d'échec ; `nil` tant que tout va bien.
    private(set) var failure: Failure?

    init(entryReader: ZipEntryReader, deadline: ContinuousClock.Instant) {
        self.entryReader = entryReader
        self.deadline = deadline
        super.init(data: Data())
    }

    /// Octets décompressés rendus à l'analyseur (diagnostic et tests).
    var inflatedByteCount: UInt64 { entryReader.producedByteCount }

    /// Le collecteur en a assez : fin de flux immédiate.
    func stop() { stopRequested = true }

    // MARK: InputStream

    override func open() {
        if status == .notOpen { status = .open }
    }

    override func close() { status = .closed }

    override var streamStatus: Stream.Status { status }

    override var streamError: (any Error)? {
        failure == nil ? nil : NSError(domain: "Triva.WordXMLInputStream", code: 1)
    }

    override var hasBytesAvailable: Bool { !stopRequested && failure == nil && status != .atEnd }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        if failure != nil { return -1 }
        if stopRequested || status == .atEnd { return 0 }
        if Task.isCancelled { return fail(.cancelled) }
        if ContinuousClock.now >= deadline { return fail(.timedOut) }
        let produced: Int
        do {
            produced = try entryReader.read(into: buffer, capacity: min(length, Self.chunkByteCount))
        } catch ZipArchiveError.tooLarge {
            return fail(.tooLarge)
        } catch {
            return fail(.corrupt)
        }
        guard produced > 0 else {
            status = .atEnd
            return 0
        }
        guard !containsDoctype(buffer, count: produced) else { return fail(.hostile) }
        return produced
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length: UnsafeMutablePointer<Int>) -> Bool {
        false
    }

    // MARK: Interne

    private func fail(_ reason: Failure) -> Int {
        failure = reason
        status = .error
        return -1
    }

    /// Cherche `<!DOCTYPE` dans le bloc, en tenant compte des octets laissés par le bloc précédent.
    private func containsDoctype(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        let marker = Self.doctypeMarker
        let overlap = marker.count - 1
        // Un marqueur à cheval : la fin du bloc précédent + le début de celui-ci.
        if !carried.isEmpty {
            let joined = carried + Array(UnsafeBufferPointer(start: buffer, count: min(count, overlap)))
            if Self.contains(marker, in: joined) { return true }
        }
        let found = marker.withUnsafeBufferPointer { pattern in
            memmem(buffer, count, pattern.baseAddress, pattern.count) != nil
        }
        let tail = Array(UnsafeBufferPointer(start: buffer + max(0, count - overlap), count: min(count, overlap)))
        carried = count >= overlap ? tail : Array((carried + tail).suffix(overlap))
        return found
    }

    private static func contains(_ marker: [UInt8], in bytes: [UInt8]) -> Bool {
        guard bytes.count >= marker.count else { return false }
        for start in 0...(bytes.count - marker.count) where Array(bytes[start..<(start + marker.count)]) == marker {
            return true
        }
        return false
    }
}
