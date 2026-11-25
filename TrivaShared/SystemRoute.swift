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

/// Une information à montrer sous les capsules de la fenêtre (le texte vit dans l'app, pas ici).
nonisolated enum SystemNotice: Sendable, Equatable {
    /// Le texte partagé a été coupé aux 2 000 premiers caractères.
    case truncatedText
    /// Le fichier partagé n'a pas pu être copié dans l'app (disque plein, fichier protégé).
    case fileNotCopied
}

/// Une demande de navigation venue de l'extérieur de la fenêtre.
nonisolated enum SystemRoute: Sendable, Equatable {
    /// Recherche vide, curseur dans la barre de saisie.
    case newQuestion(ComposerEntryKind)
    /// Texte placé dans la barre de saisie, JAMAIS envoyé. Assaini (`ExternalQuerySanitizer`) avant d'arriver à l'écran.
    case draft(String)
    /// Une conversation de l'historique.
    case conversation(UUID)
    /// Fichier reçu par l'extension de partage (PDF ou image), DÉJÀ copié dans les dépôts de l'app (`_deposits`) :
    /// il est joint à la conversation de la fenêtre, JAMAIS envoyé. Une route qui pointe ailleurs que dans les dépôts
    /// est jetée par `SystemRouteCenter`. Elle ne s'exprime pas en URL `triva://`.
    case attachment(URL)
    /// Une information à afficher (texte coupé, fichier non copié) : n'ouvre rien et n'envoie rien.
    case notice(SystemNotice)
}
