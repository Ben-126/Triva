//
//  ZipEntryReader.swift
//  Triva
//
//  Mission W (lecture des .docx) : lit le contenu d'UNE entrée d'une archive ZIP, PAR BLOCS, sans jamais le construire
//  en mémoire. Source d'octets (fichier ou mémoire) → blocs compressés de 64 Ko → DEFLATE brut (`COMPRESSION_ZLIB` de
//  l'API Compression d'Apple, qui est le DEFLATE de la RFC 1951, celui du format ZIP) → blocs décompressés rendus à
//  l'appelant, qui peut s'arrêter quand il en a assez.
//
//  Garde-fous (la taille annoncée par l'archive n'est JAMAIS crue) :
//  - la sortie ne peut dépasser ni la taille annoncée (sinon `malformed` : l'archive ment) ni le plafond de l'appelant
//    (sinon `tooLarge`) ; l'une ou l'autre arrête la décompression au bloc près ;
//  - une entrée dont les octets compressés s'arrêtent avant la fin du flux est tronquée (`malformed`) ;
//  - aucune boucle sans progrès : un bloc qui ne consomme ni ne produit rien est une erreur.
//

import Compression
import Foundation

nonisolated final class ZipEntryReader {
    static let inputChunkByteCount = 64 * 1_024

    private let source: any ZipByteSource
    private let isStored: Bool
    private let declaredByteCount: UInt64
    private let maxOutputByteCount: UInt64
    private let inputEnd: UInt64
    private var inputPosition: UInt64

    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let stream: UnsafeMutablePointer<compression_stream>
    private var isStreamReady = false
    private var hasReachedEnd = false

    /// Octets décompressés rendus jusqu'ici.
    private(set) var producedByteCount: UInt64 = 0

    /// - Parameters:
    ///   - range: où se trouvent les octets compressés (`ZipArchiveIndex.dataRange(of:in:)`).
    ///   - maxOutputByteCount: plafond dur de la sortie ; au-delà, `tooLarge`.
    /// - Throws: `unsupported` pour une méthode autre que 0 (stocké) ou 8 (DEFLATE).
    init(source: any ZipByteSource, entry: ZipEntry, range: Range<UInt64>, maxOutputByteCount: UInt64) throws {
        guard entry.method == 0 || entry.method == 8 else { throw ZipArchiveError.unsupported }
        self.source = source
        self.isStored = entry.method == 0
        self.declaredByteCount = entry.uncompressedSize
        self.maxOutputByteCount = maxOutputByteCount
        self.inputPosition = range.lowerBound
        self.inputEnd = range.upperBound
        self.inputBuffer = .allocate(capacity: Self.inputChunkByteCount)
        self.stream = .allocate(capacity: 1)
        stream.initialize(to: compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        ))
        if !isStored {
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                stream.deallocate()
                inputBuffer.deallocate()
                throw ZipArchiveError.malformed
            }
            isStreamReady = true
        }
        stream.pointee.src_ptr = UnsafePointer(inputBuffer)
        stream.pointee.src_size = 0
    }

    deinit {
        if isStreamReady { compression_stream_destroy(stream) }
        stream.deallocate()
        inputBuffer.deallocate()
    }

    /// Remplit `buffer` (au plus `capacity` octets) ; rend 0 quand l'entrée est terminée ET que sa taille est celle annoncée.
    /// - Throws: `malformed` (tronquée, corrompue, plus longue ou plus courte que annoncée), `tooLarge` (plafond de sortie).
    func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> Int {
        guard capacity > 0 else { return 0 }
        if !hasReachedEnd {
            let produced = isStored ? try readStored(into: buffer, capacity: capacity) : try readDeflated(into: buffer, capacity: capacity)
            try account(produced)
            if produced > 0 { return produced }
        }
        // Fin d'entrée : la taille produite doit être EXACTEMENT celle annoncée.
        guard producedByteCount == declaredByteCount else { throw ZipArchiveError.malformed }
        return 0
    }

    // MARK: - Stocké (méthode 0)

    private func readStored(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> Int {
        let remaining = inputEnd - inputPosition
        guard remaining > 0 else {
            hasReachedEnd = true
            return 0
        }
        let wanted = Int(min(UInt64(capacity), remaining))
        let data: Data
        do { data = try source.read(at: inputPosition, length: wanted) } catch { throw ZipArchiveError.malformed }
        guard data.count == wanted else { throw ZipArchiveError.malformed }
        data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: wanted))
        inputPosition += UInt64(wanted)
        return wanted
    }

    // MARK: - DEFLATE (méthode 8)

    private func readDeflated(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> Int {
        stream.pointee.dst_ptr = buffer
        stream.pointee.dst_size = capacity
        while true {
            try refillInputIfNeeded()
            let noMoreInput = stream.pointee.src_size == 0 && inputPosition >= inputEnd
            let sourceBefore = stream.pointee.src_size
            let flags: Int32 = noMoreInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = capacity - stream.pointee.dst_size

            switch status {
            case COMPRESSION_STATUS_ERROR:
                throw ZipArchiveError.malformed
            case COMPRESSION_STATUS_END:
                hasReachedEnd = true
                return produced
            default:
                if produced > 0 { return produced }
                // Ni sortie ni entrée consommée, ou entrée épuisée sans fin de flux : l'entrée est tronquée.
                if noMoreInput || stream.pointee.src_size == sourceBefore { throw ZipArchiveError.malformed }
            }
        }
    }

    /// Recharge le bloc compressé quand le précédent est entièrement consommé.
    private func refillInputIfNeeded() throws {
        guard stream.pointee.src_size == 0, inputPosition < inputEnd else { return }
        let wanted = Int(min(UInt64(Self.inputChunkByteCount), inputEnd - inputPosition))
        let data: Data
        do { data = try source.read(at: inputPosition, length: wanted) } catch { throw ZipArchiveError.malformed }
        guard data.count == wanted else { throw ZipArchiveError.malformed }
        data.copyBytes(to: UnsafeMutableBufferPointer(start: inputBuffer, count: wanted))
        inputPosition += UInt64(wanted)
        stream.pointee.src_ptr = UnsafePointer(inputBuffer)
        stream.pointee.src_size = wanted
    }

    // MARK: - Comptabilité

    private func account(_ produced: Int) throws {
        producedByteCount += UInt64(produced)
        // L'archive annonce une taille : une entrée plus longue ment, on s'arrête tout de suite.
        guard producedByteCount <= declaredByteCount else { throw ZipArchiveError.malformed }
        guard producedByteCount <= maxOutputByteCount else { throw ZipArchiveError.tooLarge }
    }
}
