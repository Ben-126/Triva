//
//  ReadPageAction.swift
//  Triva
//
//  Comment « Lire cette page » agit selon l'écran : dans le chat, la lecture refait la réponse en
//  cours (mission C5) ; ailleurs (détail d'un favori), elle lit seulement. La liste des sources
//  lit cette valeur dans l'environnement plutôt que de la recevoir par chaque couche de vues.
//

import SwiftUI

/// Action « Lire cette page » fournie par l'écran qui sait refaire une réponse.
struct ReadPageAction {
    /// Faux pendant une génération : le bouton est désactivé (une seule génération à la fois).
    var isEnabled: Bool
    var perform: @MainActor (String) async -> Void
}

extension EnvironmentValues {
    /// `nil` : lecture simple (sans relance), comme dans le détail d'un favori.
    @Entry var readPageAction: ReadPageAction?
}
