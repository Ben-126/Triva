//
//  SystemRoute.swift
//  TrivaShared
//
//  Chantier 2.1 (mission A) : ce que le système (widget, Raccourcis, Siri, Spotlight, partage, activité en
//  direct) peut demander à l'app. Une route NAVIGUE, elle n'ENVOIE JAMAIS rien : un texte reçu va dans la barre
//  de saisie, l'utilisateur le relit puis l'envoie lui-même.
//

import Foundation

/// Comment l'utilisateur veut saisir sa question. `.voice` est le point d'entrée du chantier 2.7 : tant que
/// `TrivaFeatureFlags.voiceInput` est faux, il ouvre le clavier comme `.keyboard`.
nonisolated enum ComposerEntryKind: Sendable, Equatable, Hashable {
    case keyboard
    case voice
}

/// Une demande de navigation venue de l'extérieur de la fenêtre.
nonisolated enum SystemRoute: Sendable, Equatable {
    /// Recherche vide, curseur dans la barre de saisie.
    case newQuestion(ComposerEntryKind)
    /// Texte placé dans la barre de saisie, JAMAIS envoyé. Assaini (`ExternalQuerySanitizer`) avant d'arriver à l'écran.
    case draft(String)
    /// Une conversation de l'historique.
    case conversation(UUID)
}
