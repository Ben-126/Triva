//
//  HandoffStreamTransferTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : le transfert par les flux de continuation, essayé sur de VRAIES paires de flux liées
//  (`Stream.getBoundStreams`), côté envoi et côté réception en même temps : coupure, délai, données hostiles ou tronquées,
//  annulation. Aucun test ne touche au réseau ni à `NSUserActivity` (il faut deux appareils réels pour ça).
//

import Foundation
import Testing
@testable import Triva

/// Les quatre bouts de deux tuyaux : ce que le système donne à chaque côté d'un Handoff.
private struct BoundEnds: @unchecked Sendable {
    let receiver: HandoffStreamPair
    let originator: HandoffStreamPair
    /// Bouts que le test garde pour jouer un côté à la main.
    let receiverToOriginator: OutputStream
    let originatorToReceiver: OutputStream

    init(bufferSize: Int = 4_096) {
        var originatorIn: InputStream?, receiverOut: OutputStream?
        var receiverIn: InputStream?, originatorOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &originatorIn, outputStream: &receiverOut)
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &receiverIn, outputStream: &originatorOut)
        receiver = HandoffStreamPair(input: receiverIn!, output: receiverOut!)
        originator = HandoffStreamPair(input: originatorIn!, output: originatorOut!)
        receiverToOriginator = receiverOut!
        originatorToReceiver = originatorOut!
    }
}

@Suite("Handoff conversation : flux", .timeLimit(.minutes(1)))
struct HandoffStreamTransferTests {
    private let id = HandoffFixtures.conversationID

    @Test("De bout en bout : l'envoyeur sert la discussion, le receveur la reçoit à l'identique")
    func endToEnd() async throws {
        let ends = BoundEnds()
        let snapshot = HandoffFixtures.snapshot(pairs: 4)
        let data = try #require(HandoffSnapshotCodec.encode(snapshot)).data
        async let served: Void = HandoffStreamTransfer.serve(over: ends.originator, timeout: .seconds(5)) { data }
        let received = try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .seconds(5))
        try await served
        #expect(received == snapshot)
    }

    @Test("Gros contenu (près de 1 Mo) : passe par un tuyau de 4 Ko, lu et écrit en même temps")
    func largePayloadFlows() async throws {
        let ends = BoundEnds()
        var snapshot = HandoffFixtures.snapshot(pairs: 0)
        for index in 0..<20 {
            snapshot.messages.append(HandoffFixtures.message(index, text: String(repeating: "é", count: 45_000)))
        }
        let data = try #require(HandoffSnapshotCodec.encode(snapshot)).data
        #expect(data.count > 800_000)
        async let served: Void = HandoffStreamTransfer.serve(over: ends.originator, timeout: .seconds(20)) { data }
        let received = try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .seconds(20))
        try await served
        #expect(received.messages.count == 20)
    }

    @Test("L'envoyeur n'a plus rien à servir (réglage éteint, conversation supprimée) : il ferme, le receveur le sait")
    func refusedByOriginator() async throws {
        let ends = BoundEnds()
        async let served: Void = HandoffStreamTransfer.serve(over: ends.originator, timeout: .seconds(5)) { nil }
        await #expect(throws: HandoffTransferError.closedEarly) {
            try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .seconds(5))
        }
        try? await served
    }

    @Test("Coupure en plein envoi : le receveur échoue proprement (jamais une discussion à moitié reçue)")
    func truncatedStream() async throws {
        let ends = BoundEnds()
        let data = try #require(HandoffSnapshotCodec.encode(HandoffFixtures.snapshot(pairs: 6))).data
        let frame = HandoffStreamTransfer.frame(for: data)
        let half = frame.prefix(frame.count / 2)
        let writer = Task.detached {
            ends.originator.input.open()
            ends.originator.output.open()
            // Il lit la requête, répond à moitié, puis coupe.
            var buffer = [UInt8](repeating: 0, count: 16)
            _ = ends.originator.input.read(&buffer, maxLength: 16)
            half.withUnsafeBytes { raw in
                _ = ends.originator.output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: half.count)
            }
            ends.originator.output.close()
        }
        await #expect(throws: HandoffTransferError.closedEarly) {
            try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .seconds(5))
        }
        await writer.value
    }

    @Test("Délai dépassé : le receveur abandonne dans le temps imparti quand l'autre côté se tait")
    func timesOut() async throws {
        let ends = BoundEnds()
        let started = ContinuousClock.now
        await #expect(throws: HandoffTransferError.timedOut) {
            try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .milliseconds(400))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        _ = ends.originator
    }

    @Test("Annulation : une tâche annulée rend la main tout de suite, sans attendre le délai")
    func cancellation() async throws {
        let ends = BoundEnds()
        let task = Task {
            try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: HandoffTransferError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        _ = ends.originator
    }

    @Test("Données hostiles : mauvaise signature, longueur énorme, JSON absurde : refusés")
    func hostileFrames() async throws {
        // Mauvaise signature.
        try await expectReceiverFailure(.badFrame) { Data("PIRATE!!\u{0}\u{0}\u{0}\u{1}x".utf8) }
        // Longueur annoncée au-delà du plafond : refusée SANS lire de contenu.
        let huge = Data("TRVH".utf8) + [HandoffStreamTransfer.protocolVersion, 0xFF, 0xFF, 0xFF, 0xFF]
        try await expectReceiverFailure(.tooLarge) { huge }
        // Trame correcte autour d'un contenu qui n'est pas une conversation.
        let junk = HandoffStreamTransfer.frame(for: Data("{\"v\":1,\"conversation\":42}".utf8))
        try await expectReceiverFailure(.invalidSnapshot(.malformed)) { junk }
        // Version de protocole inconnue.
        var futureFrame = HandoffStreamTransfer.frame(for: Data("{}".utf8))
        futureFrame[4] = 9
        let future = futureFrame
        try await expectReceiverFailure(.badFrame) { future }
    }

    @Test("Requête hostile reçue par l'envoyeur : il ne répond rien et ne sert jamais la discussion")
    func originatorRefusesBadRequest() async throws {
        let ends = BoundEnds()
        let counter = CallCounter()
        let served = Task {
            try await HandoffStreamTransfer.serve(over: ends.originator, timeout: .seconds(2)) { counter.hit(); return Data("secret".utf8) }
        }
        ends.receiverToOriginator.open()
        let bad = Data("GET / HTTP/1.1\r\n".utf8)
        bad.withUnsafeBytes { _ = ends.receiverToOriginator.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: bad.count) }
        await #expect(throws: HandoffTransferError.badFrame) { try await served.value }
        #expect(counter.count == 0)
    }

    // MARK: Aide

    /// Le receveur réel lit ce qu'un envoyeur hostile écrit (après avoir lu la requête).
    private func expectReceiverFailure(
        _ expected: HandoffTransferError,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ hostileFrame: @escaping @Sendable () -> Data
    ) async throws {
        let ends = BoundEnds()
        let frame = hostileFrame()
        let writer = Task.detached {
            ends.originator.input.open()
            ends.originator.output.open()
            var buffer = [UInt8](repeating: 0, count: 16)
            _ = ends.originator.input.read(&buffer, maxLength: 16)
            frame.withUnsafeBytes { raw in
                _ = ends.originator.output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: frame.count)
            }
            // Le tuyau reste ouvert : c'est au receveur de refuser avant d'attendre le reste.
            try? await Task.sleep(for: .seconds(1))
            ends.originator.output.close()
        }
        await #expect(throws: expected, sourceLocation: sourceLocation) {
            try await HandoffStreamTransfer.fetchSnapshot(over: ends.receiver, expectedID: id, timeout: .seconds(5))
        }
        writer.cancel()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func hit() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
