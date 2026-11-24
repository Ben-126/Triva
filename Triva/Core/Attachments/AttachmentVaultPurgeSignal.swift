//
//  AttachmentVaultPurgeSignal.swift
//  Triva
//
//  Mission K1 (2026-11-24).
//

import Foundation

/// Annonce que « Tout effacer » va supprimer TOUTES les copies temporaires de pièces jointes d'un coffre, y compris
/// celles des fenêtres ouvertes. Pourquoi : un aperçu (Coup d'œil) ouvert sur une de ces copies ne doit pas se
/// retrouver sur un fichier disparu. Chaque fenêtre ferme son aperçu et oublie ses copies
/// (`FileAttachmentController`), puis l'effaceur supprime les fichiers (`LocalDataEraser`, après un court délai).
///
/// Une notification plutôt qu'un lien direct : l'effaceur ne connaît pas les fenêtres, et plusieurs vues (capsules
/// du composeur, liste des sources) ont chacune leur aperçu. Le signal porte le DOSSIER du coffre purgé : une
/// fenêtre qui utilise un autre coffre n'est pas concernée.
nonisolated enum AttachmentVaultPurgeSignal {
    static let notificationName = Notification.Name("com.benpodrojsky.Triva.attachmentVaultWillPurge")
    private static let rootKey = "root"

    /// Main actor obligatoire (vérifié par le compilateur) : les abonnés sont avertis tout de suite, sur ce fil
    /// (`NotificationCenter.addObserver(forName:object:queue:using:)` avec `queue: nil`), et leur gestionnaire
    /// (`MainActor.assumeIsolated`) s'arrêterait net sur un autre fil.
    @MainActor
    static func post(root: URL, on center: NotificationCenter = .default) {
        center.post(name: notificationName, object: nil, userInfo: [rootKey: root.standardizedFileURL.path])
    }

    /// Dossier du coffre annoncé par `notification`, normalisé ; `nil` si la notification n'en porte pas.
    static func root(of notification: Notification) -> URL? {
        (notification.userInfo?[rootKey] as? String).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }
}

/// Abonnement d'une fenêtre au signal ; se désabonne tout seul quand la fenêtre disparaît.
nonisolated final class AttachmentVaultPurgeObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// `handler` reçoit le dossier du coffre purgé, sur le main actor, au moment du signal.
    init(center: NotificationCenter = .default, handler: @escaping @MainActor (URL?) -> Void) {
        self.center = center
        token = center.addObserver(forName: AttachmentVaultPurgeSignal.notificationName, object: nil, queue: nil) { notification in
            let root = AttachmentVaultPurgeSignal.root(of: notification)
            // Seul `AttachmentVaultPurgeSignal.post` (main actor) émet ce signal.
            MainActor.assumeIsolated { handler(root) }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
