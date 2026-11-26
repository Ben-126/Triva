//
//  HandoffStreamTransfer.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : le dialogue sur les flux de continuation, ouvert par le receveur.
//
//    receveur  --> « TRVQ » + version                      (5 octets : la requête)
//    envoyeur  --> « TRVH » + version + longueur + contenu (la discussion codée, `HandoffSnapshotCodec`)
//
//  La doc d'Apple décrit « une requête de l'app qui continue et une réponse de l'app d'origine ». Le receveur ouvre et
//  ferme tout ; l'envoyeur refuse une requête illisible sans rien répondre. Chaque phase a un délai et reste annulable
//  (`HandoffStreamPump`). La longueur annoncée est contrôlée AVANT de lire le contenu.
//

import Foundation

nonisolated enum HandoffStreamTransfer {
    /// Version du protocole de trame (octet qui suit la signature).
    static let protocolVersion: UInt8 = 1
    static let defaultTimeout: Duration = .seconds(10)

    private static let requestMagic = Array("TRVQ".utf8)
    private static let responseMagic = Array("TRVH".utf8)
    private static let requestLength = 5
    private static let responseHeaderLength = 9

    // MARK: Trames

    /// Signature + version + longueur (4 octets, grand-boutiste) + contenu.
    static func frame(for payload: Data) -> Data {
        var frame = Data(responseMagic)
        frame.append(protocolVersion)
        var length = UInt32(clamping: payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private static func requestFrame() -> Data {
        Data(requestMagic + [protocolVersion])
    }

    // MARK: Receveur

    /// Demande la discussion à l'appareil d'origine.
    /// - Throws: `HandoffTransferError` (délai, coupure, trame refusée, contenu refusé), jamais un contenu partiel.
    @concurrent
    static func fetchSnapshot(
        over streams: HandoffStreamPair,
        expectedID: UUID,
        timeout: Duration = defaultTimeout,
        maxPayload: Int = HandoffSnapshotCodec.maxPayloadBytes
    ) async throws -> HandoffConversationSnapshot {
        let data = try await HandoffStreamPump.run(on: streams, timeout: timeout) { pair in
            pair.input.open()
            pair.output.open()
            defer {
                pair.input.close()
                pair.output.close()
            }
            try writeAll(requestFrame(), to: pair.output)
            let header = try readExactly(responseHeaderLength, from: pair.input)
            guard Array(header.prefix(4)) == responseMagic, header[4] == protocolVersion else {
                throw HandoffTransferError.badFrame
            }
            let length = header.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxPayload else { throw HandoffTransferError.tooLarge }
            return try readExactly(length, from: pair.input)
        }
        do {
            return try HandoffSnapshotCodec.decode(data, expectedConversationID: expectedID, maxBytes: maxPayload)
        } catch let error as HandoffSnapshotError {
            throw HandoffTransferError.invalidSnapshot(error)
        }
    }

    // MARK: Envoyeur

    /// Répond à la requête de l'appareil qui continue. `payload` est lu sur le main actor, AU MOMENT de répondre : `nil`
    /// (réglage éteint depuis, conversation supprimée) ferme les flux sans rien envoyer.
    static func serve(
        over streams: HandoffStreamPair,
        timeout: Duration = defaultTimeout,
        payload: @escaping @MainActor @Sendable () -> Data?
    ) async throws {
        try await HandoffStreamPump.run(on: streams, timeout: timeout) { pair in
            pair.input.open()
            pair.output.open()
            let request = try readExactly(requestLength, from: pair.input)
            guard Array(request.prefix(4)) == requestMagic, request[4] == protocolVersion else {
                pair.input.close()
                pair.output.close()
                throw HandoffTransferError.badFrame
            }
        }
        guard let data = await MainActor.run(body: payload), data.count <= HandoffSnapshotCodec.maxPayloadBytes else {
            close(streams)
            return
        }
        try await HandoffStreamPump.run(on: streams, timeout: timeout) { pair in
            defer { close(pair) }
            try writeAll(frame(for: data), to: pair.output)
        }
    }

    // MARK: Entrées-sorties bloquantes

    private static func close(_ pair: HandoffStreamPair) {
        pair.input.close()
        pair.output.close()
    }

    private static func readExactly(_ count: Int, from input: InputStream) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < count {
                let read = input.read(base + offset, maxLength: count - offset)
                guard read > 0 else { throw HandoffTransferError.closedEarly }
                offset += read
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, to output: OutputStream) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = output.write(base + offset, maxLength: data.count - offset)
                guard written > 0 else { throw HandoffTransferError.closedEarly }
                offset += written
            }
        }
    }
}
