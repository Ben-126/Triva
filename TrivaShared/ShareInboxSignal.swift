//
//  ShareInboxSignal.swift
//  TrivaShared
//
//  Mission X1 (R2-07) : l'extension de partage prévient l'app que la boîte a une nouvelle entrée. Sans ce signal,
//  l'app ne reprend un partage qu'à son passage au premier plan : si elle était déjà active (Safari intégré,
//  iPad en Split View), « Ouvre Triva… » s'affichait mais rien n'arrivait.
//
//  Notification Darwin (`notify_post`) : sans contenu, elle ne dit pas CE qui a été déposé ; l'app relit la boîte.
//  Une app suspendue ne la reçoit pas : le passage au premier plan reste le chemin normal.
//
//  Compilé dans l'app ET dans l'extension.
//

import Foundation
import notify

nonisolated enum ShareInboxSignal {
    static let name = "\(AppGroup.identifier).share-inbox.changed"

    /// L'extension vient d'écrire une entrée.
    static func post(name: String = name) {
        notify_post(name)
    }

    /// Une inscription au signal ; elle se désinscrit à sa disparition ou par `cancel()`.
    final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var token: Int32
        private var isCancelled = false

        fileprivate init(token: Int32) { self.token = token }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            guard !isCancelled else { return }
            isCancelled = true
            notify_cancel(token)
        }

        deinit { cancel() }
    }

    /// Appelle `handler` (sur la file principale) à chaque signal. `nil` si le système refuse l'inscription.
    static func observe(name: String = name, handler: @escaping @Sendable () -> Void) -> Observation? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in handler() }
        guard status == UInt32(NOTIFY_STATUS_OK) else { return nil }
        return Observation(token: token)
    }
}
