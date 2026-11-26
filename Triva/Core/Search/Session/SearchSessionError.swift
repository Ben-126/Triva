//
//  SearchSessionError.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Erreurs propres à `SearchSession`.
enum SearchSessionError: Error, Sendable, Equatable {
    /// La session de recherche a été libérée (fenêtre fermée, ou changement de
    /// moteur IA qui reconstruit toute la session) alors qu'une génération
    /// était encore en vol.
    ///
    /// Le cas courant est déjà couvert sans passer par ici : `SearchSession.deinit`
    /// arrête la génération (`ChatViewModel.stopEverything()`), que `ChatViewModel` traite
    /// comme un arrêt volontaire. Reste la course de la fermeture de fenêtre
    /// pendant une génération, où la session peut être libérée avant que
    /// l'annulation ne soit constatée :
    /// `ChatViewModel.userFacingMessage(for:)` lui donne un message français
    /// (I2). Levée aussi par le chargement de Découvrir si la session a
    /// disparu (`TrivaRootCoordinator`), qui s'affiche alors comme un échec
    /// de chargement ordinaire. On préfère une erreur explicite à un
    /// `unowned self`, qui ferait planter l'app au lieu de le signaler.
    case sessionEnded
}
