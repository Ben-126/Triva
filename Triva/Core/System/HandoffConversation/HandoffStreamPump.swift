//
//  HandoffStreamPump.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : lire et écrire sur les flux de continuation SANS jamais rester bloqué. Les flux du système
//  ne sont pas programmés sur une boucle d'événements : `read` et `write` bloquent. Le travail bloquant tourne donc sur une
//  file à part, et une minuterie ferme les flux au bout du délai (ou à l'annulation) : le travail bloqué échoue, et
//  l'appelant, lui, reprend la main tout de suite quoi qu'il arrive.
//

import Foundation

/// Les deux bouts d'un côté de la connexion : ce que le système donne à chaque appareil.
/// `@unchecked Sendable` : `InputStream` et `OutputStream` ne le sont pas, mais chaque bout n'est manipulé que par un
/// seul travail à la fois (voir `HandoffStreamPump.run`).
nonisolated struct HandoffStreamPair: @unchecked Sendable {
    let input: InputStream
    let output: OutputStream
}

nonisolated enum HandoffTransferError: Error, Equatable, Sendable {
    case timedOut
    case cancelled
    /// L'autre appareil a fermé ou coupé avant la fin.
    case closedEarly
    /// Contenu annoncé plus grand que le plafond : refusé sans lire le contenu.
    case tooLarge
    /// Signature ou version du protocole inconnue.
    case badFrame
    /// Le système n'a pas donné de flux (`getContinuationStreams` en erreur).
    case noStreams
    case invalidSnapshot(HandoffSnapshotError)
}

nonisolated enum HandoffStreamPump {
    /// Exécute `body` (qui peut bloquer sur les flux) avec un délai et une annulation.
    ///
    /// - Parameter streams: fermés à l'expiration du délai ou à l'annulation, ce qui fait échouer `body` s'il est bloqué.
    static func run<T: Sendable>(
        on streams: HandoffStreamPair,
        timeout: Duration,
        body: @escaping @Sendable (HandoffStreamPair) throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                let timer = DispatchWorkItem { gate.finish(.failure(HandoffTransferError.timedOut), closing: streams) }
                gate.timer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let value = try body(streams)
                        gate.finish(.success(value), closing: nil)
                    } catch {
                        gate.finish(.failure(error), closing: nil)
                    }
                }
                // Annulée avant même l'installation : le gestionnaire ci-dessous est déjà passé.
                if Task.isCancelled { gate.finish(.failure(HandoffTransferError.cancelled), closing: streams) }
            }
        } onCancel: {
            gate.finish(.failure(HandoffTransferError.cancelled), closing: streams)
        }
    }

    /// Un seul résultat, quel que soit l'ordre d'arrivée (travail fini, délai, annulation).
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var done = false
        private var pendingResult: (Result<T, any Error>, HandoffStreamPair?)?
        var timer: DispatchWorkItem?

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            if let pending = pendingResult {
                done = true
                lock.unlock()
                resume(continuation, with: pending.0, closing: pending.1)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ result: Result<T, any Error>, closing streams: HandoffStreamPair?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            guard let continuation else {
                // Annulation arrivée avant `install` : le résultat attend la continuation.
                if pendingResult == nil { pendingResult = (result, streams) }
                lock.unlock()
                return
            }
            done = true
            self.continuation = nil
            lock.unlock()
            resume(continuation, with: result, closing: streams)
        }

        private func resume(_ continuation: CheckedContinuation<T, any Error>, with result: Result<T, any Error>, closing streams: HandoffStreamPair?) {
            timer?.cancel()
            if let streams {
                streams.input.close()
                streams.output.close()
            }
            continuation.resume(with: result)
        }
    }
}
