//
//  OpenConversationInNewWindow.swift
//  Triva
//
//  Chantier 2.2 (M2) : « Ouvrir dans une nouvelle fenêtre » (Mac, iPad).
//

import SwiftUI

/// Action « ouvrir cette conversation dans sa propre fenêtre ».
///
/// Par l'environnement, comme `openSearchKeySettings` : la Bibliothèque et le
/// détail d'un favori la lisent sans en connaître la mécanique (`openWindow`,
/// identifiant de scène). Posée à `nil` quand l'appareil n'a qu'une fenêtre
/// (iPhone) : l'entrée de menu n'apparaît alors pas du tout, plutôt que grisée.
nonisolated struct OpenConversationInNewWindowAction: Sendable, Equatable {
    private let ownerID: ObjectIdentifier
    private let handler: @MainActor (UUID) -> Void

    /// - Parameter owner: l'objet stable qui détient l'action (`TrivaRootCoordinator`).
    init(owner: AnyObject, handler: @escaping @MainActor (UUID) -> Void) {
        ownerID = ObjectIdentifier(owner)
        self.handler = handler
    }

    @MainActor
    func callAsFunction(_ conversationID: UUID) {
        handler(conversationID)
    }

    static func == (lhs: OpenConversationInNewWindowAction, rhs: OpenConversationInNewWindowAction) -> Bool {
        lhs.ownerID == rhs.ownerID
    }
}

extension EnvironmentValues {
    /// Posée par la coquille (`TrivaRootShell`) seulement si l'appareil sait ouvrir plusieurs
    /// fenêtres (`supportsMultipleWindows`). `nil` : aperçus, iPhone.
    @Entry var openConversationInNewWindow: OpenConversationInNewWindowAction? = nil
}

/// Libellé commun des deux endroits qui proposent l'action (menu contextuel).
enum NewWindowMenuLabel {
    static let title = "Ouvrir dans une nouvelle fenêtre"
    static let systemImage = "macwindow.badge.plus"
}
