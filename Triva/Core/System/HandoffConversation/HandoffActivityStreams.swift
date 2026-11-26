//
//  HandoffActivityStreams.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : le côté RÉCEPTION des flux. `getContinuationStreams` ne marche que sur l'`NSUserActivity` que
//  le système remet à l'app pour la continuation : on l'appelle donc SYNCHRONEMENT, dans le rappel de réception, avant tout
//  `await`. Le résultat est gardé ici ; `streams()` l'attend (une seule fois, sans jamais redemander).
//

import Foundation

nonisolated final class HandoffActivityStreams: HandoffStreamSource, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<HandoffStreamPair, any Error>?
    private var waiters: [CheckedContinuation<HandoffStreamPair, any Error>] = []

    /// Demande les flux tout de suite. Appeler depuis le rappel de réception de l'activité.
    init(activity: NSUserActivity) {
        activity.getContinuationStreams { [self] input, output, error in
            if let input, let output {
                deliver(.success(HandoffStreamPair(input: input, output: output)))
            } else {
                deliver(.failure(error ?? HandoffTransferError.noStreams))
            }
        }
    }

    func streams() async throws -> HandoffStreamPair {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func deliver(_ outcome: Result<HandoffStreamPair, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(with: outcome) }
    }
}
